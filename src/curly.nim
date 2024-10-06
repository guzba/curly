when not defined(nimdoc):
  when not defined(gcArc) and not defined(gcOrc):
    {.error: "Using --mm:arc or --mm:orc is required by Curly.".}

when not compileOption("threads"):
  {.error: "Using --threads:on is required by Curly.".}

import std/strutils, std/locks, std/random, webby/httpheaders, zippy,
    std/deques, std/tables, std/options

import libcurl except Option

when not defined(windows):
  import std/posix

export httpheaders

block:
  let ret = global_init(GLOBAL_DEFAULT)
  if ret != E_OK:
    raise newException(Defect, $easy_strerror(ret))

  let data = version_info(VERSION_NOW)
  if (data.features and VERSION_ASYNCHDNS) == 0:
    echo "Curly warning: libcurl does not have CURL_VERSION_ASYNCHDNS bit set"

when defined(windows):
  const
    libname = "libcurl.dll"
elif defined(macosx):
  const
    libname = "libcurl(|.4).dylib"
elif defined(unix):
  const
    libname = "libcurl.so(|.4)"

proc multi_poll(
  multi_handle: PM,
  extra_fds: pointer,
  extra_nfds: uint32,
  timeout_ms: int32,
  numfds: var int32
): Mcode
  {.cdecl, dynlib: libname, importc: "curl_multi_poll".}

type
  Response* = object
    code*: int ## HTTP status code of the response
    url*: string ## Final URL, after any redirects
    headers*: HttpHeaders
    body*: string ## The response body (uncompressed if gzip'ed)
    request*: RequestInfo ## Info about the request this response is for

  RequestInfo* = object
    verb*: string ## HTTP method / verb of the request
    url*: string ## Intitial request URL, before any redirects
    tag*: string ## Arbtitrary user-provided data when batching requests

  RequestBatch* = object
    requests: seq[BatchedRequest]

  BatchedRequest* = object
    verb*: string
    url*: string
    headers*: HttpHeaders
    body*: string
    tag*: string

  ResponseBatch* = seq[tuple[response: Response, error: string]]

  WaitGroupObj = object
    lock: Lock
    cond: Cond
    count: int

  WaitGroup = ptr WaitGroupObj

  RequestWrapObj = object
    verb: string
    url: string
    headers: HttpHeaders
    ignore: string
    body: pointer
    bodyLen: int
    timeout: int
    tag: string
    waitGroup: WaitGroup
    headerStringsForLibcurl: seq[string]
    slistsForLibcurl: seq[Slist]
    pslistForLibcurl: Pslist
    responseHeadersForLibcurl: string
    responseBodyForLibcurl: string
    response: Response
    error: string

  RequestWrap = ptr RequestWrapObj

  CurlyObj* = object
    lock: Lock
    cond: Cond
    requestCompletedCond: Cond
    multiHandle: PM
    maxInFlight: int
    availableEasyHandles: Deque[PCurl]
    queue: Deque[RequestWrap]
    inFlight: Table[PCurl, RequestWrap]
    requestsCompleted: Deque[RequestWrap]
    thread: Thread[Curly]
    closeCalled: bool

  Curly* = ptr CurlyObj

{.push stackTrace: off.}

proc curlHeaderWriteFn(
  buffer: cstring,
  size: int,
  count: int,
  outstream: pointer
): int {.cdecl.} =
  let
    request = cast[RequestWrap](outstream)
    i = request.responseHeadersForLibcurl.len
  request.responseHeadersForLibcurl.setLen(i + count)
  copyMem(request.responseHeadersForLibcurl[i].addr, buffer, count)
  result = size * count

proc curlBodyWriteFn(
  buffer: cstring,
  size: int,
  count: int,
  outstream: pointer
): int {.cdecl.} =
  let
    request = cast[RequestWrap](outstream)
    i = request.responseBodyForLibcurl.len
  request.responseBodyForLibcurl.setLen(i + count)
  copyMem(request.responseBodyForLibcurl[i].addr, buffer, count)
  result = size * count

{.pop.}

proc prepHeadersForLibcurl(rw: RequestWrap) =
  for (k, v) in rw.headers:
    rw.headerStringsForLibcurl.add k & ": " & v

  # Create the Pslist for passing headers to curl manually. This is to
  # avoid needing to call slist_free_all which creates problems
  for i, header in rw.headers:
    rw.slistsForLibcurl.add(
      Slist(data: rw.headerStringsForLibcurl[i].cstring, next: nil)
    )
  # Do this in two passes so the slists index addresses are stable
  for i, header in rw.headers:
    if i == 0:
      rw.pslistForLibcurl = rw.slistsForLibcurl[0].addr
    else:
      var tail = rw.pslistForLibcurl
      while tail.next != nil:
        tail = tail.next
      tail.next = rw.slistsForLibcurl[i].addr

proc addHeaders(dst: var HttpHeaders, src: string) =
  let headerLines = src.split("\r\n")
  for i, headerLine in headerLines:
    if i == 0:
      continue # Skip "HTTP/2 200" line
    if headerLine == "":
      continue
    let parts = headerLine.split(":", 1)
    if parts.len == 2:
      dst.add((parts[0].strip(), parts[1].strip()))
    else:
      dst.add((parts[0].strip(), ""))

proc newWaitGroup(count: int): WaitGroup =
  result = cast[WaitGroup](allocShared0(sizeof(WaitGroupObj)))
  result.count = count
  initLock(result.lock)
  initCond(result.cond)

proc wait(waitGroup: WaitGroup) =
  acquire(waitGroup.lock)
  while waitGroup.count > 0:
    wait(waitGroup.cond, waitGroup.lock)
  release(waitGroup.lock)

proc done(waitGroup: WaitGroup) =
  var signalCond: bool
  withLock waitGroup.lock:
    dec waitGroup.count
    signalCond = (waitGroup.count == 0)
  if signalCond:
    signal(waitGroup.cond)

proc destroy(waitGroup: WaitGroup) =
  deinitLock(waitGroup.lock)
  deinitCond(waitGroup.cond)
  `=destroy`(waitGroup[])
  deallocShared(waitGroup)

proc threadProc(curl: Curly) {.raises: [].} =
  when not defined(windows): # Block SIGPIPE for this thread
    var oldSet, empty: Sigset
    discard sigemptyset(oldSet)
    discard sigemptyset(empty)
    discard pthread_sigmask(SIG_BLOCK, empty, oldSet) # Read current
    var newSet = oldSet
    discard sigaddset(newSet, SIGPIPE)
    discard pthread_sigmask(SIG_BLOCK, newSet, oldSet) # Block SIGPIPE

  let
    tmp4 = allocShared0(4)
    tmpcstring = cast[ptr cstring](allocShared0(sizeof(cstring)))

  var dequeued: seq[RequestWrap]
  while true:
    if curl.availableEasyHandles.len > 0:
      withLock curl.lock:
        {.gcsafe.}:
          let
            easyHandlesAvailable = curl.availableEasyHandles.len
            entriesAvailable = curl.queue.len
          for _ in 0 ..< min(easyHandlesAvailable, entriesAvailable):
            dequeued.add(curl.queue.popFirst())

    for request in dequeued:
      let easyHandle = curl.availableEasyHandles.popFirst()

      discard easyHandle.easy_setopt(OPT_URL, request.url.cstring)
      discard easyHandle.easy_setopt(OPT_CUSTOMREQUEST, request.verb.cstring)
      discard easyHandle.easy_setopt(OPT_TIMEOUT, request.timeout)

      # Set CURLOPT_PIPEWAIT
      discard easyHandle.easy_setopt(cast[libcurl.Option](237), 1)

      discard easyHandle.easy_setopt(OPT_HTTPHEADER, request.pslistForLibcurl)

      if cmpIgnoreCase(request.verb, "HEAD") == 0:
        discard easyHandle.easy_setopt(OPT_NOBODY, 1)
      elif cmpIgnoreCase(request.verb, "POST") == 0 or request.bodyLen > 0:
        discard easyHandle.easy_setopt(OPT_POSTFIELDSIZE, request.bodyLen)
        if request.bodyLen > 0:
          discard easyHandle.easy_setopt(OPT_POSTFIELDS, request.body)

      # Follow up to 10 redirects
      discard easyHandle.easy_setopt(OPT_FOLLOWLOCATION, 1)
      discard easyHandle.easy_setopt(OPT_MAXREDIRS, 10)

      # https://curl.se/libcurl/c/threadsafe.html
      discard easyHandle.easy_setopt(OPT_NOSIGNAL, 1)

      when defined(windows):
        # CURLOPT_SSL_OPTIONS, CURLSSLOPT_NATIVE_CA
        discard easyHandle.easy_setopt(cast[libcurl.Option](216), 1 shl 4)

      # Setup writers
      discard easyHandle.easy_setopt(OPT_HEADERDATA, request)
      discard easyHandle.easy_setopt(OPT_HEADERFUNCTION, curlHeaderWriteFn)
      discard easyHandle.easy_setopt(OPT_WRITEDATA, request)
      discard easyHandle.easy_setopt(OPT_WRITEFUNCTION, curlBodyWriteFn)

      let mc = multi_add_handle(curl.multiHandle, easyHandle)
      if mc == M_OK:
        curl.inFlight[easyHandle] = request
      else:
        # Reset this easy_handle and add it back as available
        easy_reset(easyHandle)
        curl.availableEasyHandles.addLast(easyHandle)

        # Set the error so an exception is raised
        request.error = "Unexpected libcurl multi_add_handle error: " &
          $mc & ' ' & $multi_strerror(mc)

        if request.waitGroup != nil:
          request.waitGroup.done()
        else:
          withLock curl.lock:
            curl.requestsCompleted.addLast(request)
          signal(curl.requestCompletedCond)

    dequeued.setLen(0) # Reset for next loop

    var
      numRunningHandles: int32
      mc = multi_perform(curl.multiHandle, numRunningHandles)
    if mc == M_OK:
      if numRunningHandles > 0:
        var numFds: int32
        mc = multi_poll(curl.multiHandle, nil, 0, timeout_ms = 2, numFds)
        if mc != M_OK:
          # Is this fatal? When can this happen?
          echo "Unexpected libcurl multi_poll error: ",
            mc, ' ', multi_strerror(mc)
    else:
      # Is this fatal? When can this happen?
      echo "Unexpected libcurl multi_perform error: ",
        mc, ' ', multi_strerror(mc)

    while true:
      var msgsInQueue: int32
      let m = multi_info_read(curl.multiHandle, msgsInQueue)
      if m == nil:
        break
      if m.msg != MSG_DONE:
        continue

      let mc = multi_remove_handle(curl.multiHandle, m.easy_handle)
      if mc != M_OK:
        # This should never happen?
        echo "Unexpected libcurl multi_remove_handle error: ",
          mc, ' ', multi_strerror(mc)
        continue

      let request = curl.inFlight.getOrDefault(m.easy_handle, nil)
      curl.inFlight.del(m.easy_handle)
      if request == nil:
        # This should never happen
        echo "Unrecognized libcurl easy_handle from multi_info_read"
        continue

      # This request has completed
      let code = cast[Code](m.whatever)
      if code == E_OK:
        # Avoid SIGSEGV on Mac with -d:release and a memory leak on Linux
        zeroMem(tmp4, 4)
        discard m.easy_handle.easy_getinfo(INFO_RESPONSE_CODE, tmp4)
        var httpCode: uint32
        copyMem(httpCode.addr, tmp4, 4)
        request.response.code = httpCode.int
        zeroMem(tmpcstring, sizeof(cstring))
        discard m.easy_handle.easy_getinfo(INFO_EFFECTIVE_URL, tmpcstring)
        request.response.url = $tmpcstring[]
      else:
        request.error =
          $easy_strerror(code) & ' ' & request.verb & ' ' & request.url

      # Reset this easy_handle and add it back as available
      easy_reset(m.easy_handle)
      curl.availableEasyHandles.addLast(m.easy_handle)

      if request.waitGroup != nil:
        request.waitGroup.done()
      else:
        withLock curl.lock:
          curl.requestsCompleted.addLast(request)
        signal(curl.requestCompletedCond)

    if numRunningHandles == 0:
      # Sleep if there are no running handles and the queue is empty
      {.gcsafe.}:
        acquire(curl.lock)
        while curl.queue.len == 0 and not curl.closeCalled:
          wait(curl.cond, curl.lock)
        var closeCalled = curl.closeCalled
        release(curl.lock)
        # Close has been called and there are no running handles, break the
        # loop and let this thread join.
        if closeCalled:
          break

proc newCurly*(maxInFlight = 16): Curly =
  ## Creates a new Curly instance that will run up to `maxInFlight` HTTP
  ## requests in parallel.
  result = cast[Curly](allocShared0(sizeof(CurlyObj)))
  initLock(result.lock)
  initCond(result.cond)
  initCond(result.requestCompletedCond)
  result.multiHandle = multi_init()
  discard multi_setopt(
    result.multiHandle,
    cast[MOption](3), # CURLMOPT_PIPELINING
    2 # CURLPIPE_MULTIPLEX
  )
  result.maxInFlight = maxInFlight
  for i in 0 ..< maxInFlight:
    result.availableEasyHandles.addLast(easy_init())
  createThread(result.thread, threadProc, result)

proc close*(curl: Curly) =
  ## Blocks until all in-flight and queued requests complete, then
  ## closes all libcurl handles and deallocates the Curly object.
  withLock curl.lock:
    curl.closeCalled = true
  signal(curl.cond)
  joinThreads(curl.thread)
  deinitLock(curl.lock)
  deinitCond(curl.cond)
  deinitCond(curl.requestCompletedCond)
  while curl.availableEasyHandles.len > 0:
    let easyHandle = curl.availableEasyHandles.popFirst()
    easy_cleanup(easyHandle)
  discard multi_cleanup(curl.multiHandle)
  `=destroy`(curl[])
  deallocShared(curl)

proc destroy(rw: RequestWrap) {.gcsafe.} =
  `=destroy`(rw[])
  deallocShared(rw)

proc hasRequests*(curl: Curly): bool {.gcsafe.} =
  ## Returns true if there are requests in-flight or queued.
  withLock curl.lock:
    let inFlight = curl.maxInFlight - curl.availableEasyHandles.len
    result = inFlight > 0 or curl.queue.len > 0

proc numInFlight*(curl: Curly): int {.gcsafe.} =
  ## Returns the number of requests currently in-flight.
  withLock curl.lock:
    result = curl.maxInFlight - curl.availableEasyHandles.len

proc queueLen*(curl: Curly): int {.gcsafe.} =
  ## Returns the number of queued requests.
  withLock curl.lock:
    result = curl.queue.len

proc clearQueue*(curl: Curly) {.gcsafe.} =
  ## Clears the request queue, unblocking any threads waiting on responses.
  ## All queued requests are completed with an error.
  withLock curl.lock:
    while curl.queue.len > 0:
      let rw = curl.queue.popFirst()
      rw.error = "Canceled in clearQueue"
      if rw.waitGroup != nil:
        rw.waitGroup.done()
      else:
        curl.requestsCompleted.addLast(rw)

proc makeRequest*(
  curl: Curly,
  verb: sink string,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout = 60
): Response {.gcsafe.} =
  ## Makes the HTTP request and blocks until the response is received. If
  ## a response cannot be received (due to timeout, DNS failure, broken
  ## connection, etc), an exception is raised.
  let rw = cast[RequestWrap](allocShared0(sizeof(RequestWrapObj)))
  rw.verb = move verb
  rw.url = move url
  rw.headers = move headers
  if body.len > 0:
    rw.body = body[0].unsafeAddr
    rw.bodyLen = body.len
  rw.timeout = timeout
  rw.waitGroup = newWaitGroup(1)

  rw.prepHeadersForLibcurl()

  withLock curl.lock:
    curl.queue.addLast(rw)
  signal(curl.cond)

  rw.waitGroup.wait()

  try:
    if rw.error == "":
      result = move rw.response
      result.request.verb = move rw.verb
      result.request.url = move rw.url
      addHeaders(result.headers, rw.responseHeadersForLibcurl)
      result.body = move rw.responseBodyForLibcurl
      if result.headers["Content-Encoding"] == "gzip":
        result.body = uncompress(result.body, dfGzip)
    else:
      raise newException(CatchableError, move rw.error)
  finally:
    destroy rw.waitGroup
    destroy rw

proc get*(
  curl: Curly,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  timeout = 60
): Response =
  curl.makeRequest("GET", url, headers, "", timeout)

proc post*(
  curl: Curly,
  url: string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout = 60
): Response =
  curl.makeRequest("POST", url, headers, body, timeout)

proc put*(
  curl: Curly,
  url: string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout = 60
): Response =
  curl.makeRequest("PUT", url, headers, body, timeout)

proc patch*(
  curl: Curly,
  url: string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout = 60
): Response =
  curl.makeRequest("PATCH", url, headers, body, timeout)

proc delete*(
  curl: Curly,
  url: string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  timeout = 60
): Response =
  curl.makeRequest("DELETE", url, headers, "", timeout)

proc head*(
  curl: Curly,
  url: string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  timeout = 60
): Response =
  curl.makeRequest("HEAD", url, headers, "", timeout)

proc unwrapResponse(
  rw: RequestWrap
): tuple[response: Response, error: string] =
  var response = move rw.response
  response.request.verb = move rw.verb
  response.request.url = move rw.url
  response.request.tag = move rw.tag
  if rw.error == "":
    addHeaders(response.headers, rw.responseHeadersForLibcurl)
    response.body = move rw.responseBodyForLibcurl
    if response.headers["Content-Encoding"] == "gzip":
      try:
        response.body = uncompress(response.body, dfGzip)
      except:
        rw.error = "Uncompressing gzip'ed response body failed: " &
          getCurrentExceptionMsg()
  (move response, move rw.error)

proc makeRequests*(
  curl: Curly,
  batch: RequestBatch,
  timeout = 60
): ResponseBatch {.raises: [], gcsafe.} =
  ## Make multiple HTTP requests in parallel. This proc blocks until
  ## all requests have either received a response or are unable to complete.
  ## The return value seq is in the same order as the request batch.
  ## Each request will have either a response or an error in the return seq.
  ## If `error != ""` then something prevented the request from completing.
  ## This may be a timeout, DNS error, connection interruption, etc.
  ## The error string provides more information.

  if batch.requests.len == 0:
    return

  let waitGroup = newWaitGroup(batch.requests.len)

  var wrapped: seq[RequestWrap]
  for request in batch.requests:
    let rw = cast[RequestWrap](allocShared0(sizeof(RequestWrapObj)))
    rw.verb = request.verb
    rw.url = request.url
    rw.headers = request.headers
    if request.body.len > 0:
      rw.body = request.body[0].unsafeAddr
      rw.bodyLen = request.body.len
    rw.timeout = timeout
    rw.tag = request.tag
    rw.waitGroup = waitGroup

    rw.prepHeadersForLibcurl()

    wrapped.add(rw)

    withLock curl.lock:
      curl.queue.addLast(rw)

  signal(curl.cond)

  waitGroup.wait()

  for rw in wrapped:
    result.add(unwrapResponse(rw))

  destroy waitGroup

  for rw in wrapped:
    destroy rw

proc len*(batch: RequestBatch): int =
  batch.requests.len

proc `[]`*(batch: RequestBatch, i: int): lent BatchedRequest =
  batch.requests[i]

proc addRequest*(
  batch: var RequestBatch,
  verb: sink string,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: sink string = "",
  tag: sink string = ""
) =
  batch.requests.add(BatchedRequest(
    verb: move verb,
    url: move url,
    headers: move headers,
    body: move body,
    tag: move tag
  ))

proc get*(
  batch: var RequestBatch,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  tag: sink string = ""
) =
  batch.addRequest("GET", move url, move headers, "", tag)

proc post*(
  batch: var RequestBatch,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: sink string = "",
  tag: sink string = ""
) =
  batch.addRequest("POST", move url, move headers, move body, tag)

proc put*(
  batch: var RequestBatch,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: sink string = "",
  tag: sink string = ""
) =
  batch.addRequest("PUT", move url, move headers, move body, tag)

proc patch*(
  batch: var RequestBatch,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: sink string = "",
  tag: sink string = ""
) =
  batch.addRequest("PATCH", move url, move headers, move body, tag)

proc delete*(
  batch: var RequestBatch,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  tag: sink string = ""
) =
  batch.addRequest("DELETE", move url, move headers, "", tag)

proc head*(
  batch: var RequestBatch,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  tag: sink string = ""
) =
  batch.addRequest("HEAD", move url, move headers, "", tag)

proc startRequests*(
  curl: Curly,
  batch: sink RequestBatch,
  timeout = 60
) {.raises: [], gcsafe.} =
  ## Starts one or more HTTP requests. These requests are run in parallel.
  ## This proc does not block waiting for responses.
  ## NOTE: When each request completes, a response is stored until it is
  ## removed by a call to `waitForResponse` or `pollForResponse`.
  ## If the responses are never removed, they will accumulate in memory.

  if batch.requests.len == 0:
    return

  var wrapped: seq[RequestWrap]
  for request in batch.requests.mitems:
    let rw = cast[RequestWrap](allocShared0(sizeof(RequestWrapObj)))
    rw.verb = move request.verb
    rw.url = move request.url
    rw.headers = move request.headers
    rw.ignore = move request.body
    if rw.ignore.len > 0:
      rw.body = rw.ignore[0].addr
      rw.bodyLen = rw.ignore.len
    rw.timeout = timeout
    rw.tag = move request.tag

    rw.prepHeadersForLibcurl()

    wrapped.add(rw)

    withLock curl.lock:
      curl.queue.addLast(rw)

  signal(curl.cond)

proc startRequest*(
  curl: Curly,
  verb: sink string,
  url: sink string,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: sink string = "",
  timeout = 60,
  tag: sink string = ""
) {.raises: [], gcsafe.} =
  ## Starts an HTTP request. These requests are run in parallel.
  ## This proc does not block waiting for a response.
  ## NOTE: When the request completes, a response is stored until it is
  ## removed by a call to `waitForResponse`.
  ## If the responses are never removed, they will accumulate in memory.
  var batch: RequestBatch
  batch.addRequest(verb, url, headers, body, tag)
  curl.startRequests(batch, timeout)

proc waitForResponse*(
  curl: Curly
): tuple[response: Response, error: string] {.raises: [], gcsafe.} =
  ## Blocks waiting for a response to an HTTP request started by either
  ## `startRequest` or `startRequests`.
  ## Responses returned by this proc are in the order the responses are
  ## received, NOT in the order the requests were started.
  acquire(curl.lock)
  while curl.requestsCompleted.len == 0:
    wait(curl.requestCompletedCond, curl.lock)
  let rw = curl.requestsCompleted.popFirst()
  release(curl.lock)

  result = unwrapResponse(rw)

  destroy rw

type RequestResult = object
  response*: Response
  error*: string

proc pollForResponse*(
  curl: Curly
): Option[RequestResult] {.raises: [], gcsafe.} =
  ## Returns a response to an HTTP request started by either
  ## `startRequest` or `startRequests` if one is available.
  ## Responses returned by this proc are in the order the responses are
  ## received, NOT in the order the requests were started.
  var rw: RequestWrap
  acquire(curl.lock)
  if curl.requestsCompleted.len > 0:
    rw = curl.requestsCompleted.popFirst()
  release(curl.lock)

  if rw != nil:
    var (response, error) = unwrapResponse(rw)
    result = some(RequestResult(response: move response, error: move error))

# Older CurlPool implementation

type
  CurlPoolObj = object
    handles: seq[PCurl]
    lock: Lock
    cond: Cond
    r: Rand

  CurlPool* = ptr CurlPoolObj

  StringWrap = object
    str: string

proc close*(pool: CurlPool) =
  ## Closes the libcurl handles then deallocates the pool.
  ## All libcurl handles should be returned to the pool before it is closed.
  withLock pool.lock:
    for entry in pool.handles:
      easy_cleanup(entry)
  `=destroy`(pool[])
  deallocShared(pool)

proc borrow*(pool: CurlPool): PCurl {.inline, raises: [], gcsafe.} =
  ## Removes a libcurl handle from the pool. This call blocks until it can take
  ## a handle. Remember to add the handle back to the pool with recycle
  ## when you're finished with it.
  acquire(pool.lock)
  while pool.handles.len == 0:
    wait(pool.cond, pool.lock)
  result = pool.handles.pop()
  release(pool.lock)

proc recycle*(pool: CurlPool, handle: PCurl) {.inline, raises: [], gcsafe.} =
  ## Returns a libcurl handle to the pool.
  withLock pool.lock:
    pool.handles.add(handle)
    pool.r.shuffle(pool.handles)
  signal(pool.cond)

proc newCurlPool*(size: int): CurlPool =
  ## Creates a new thead-safe pool of libcurl handles.
  result = cast[CurlPool](allocShared0(sizeof(CurlPoolObj)))
  initLock(result.lock)
  initCond(result.cond)
  result.r = initRand(2023)

  try:
    for _ in 0 ..< size:
      result.recycle(easy_init())
  except:
    try:
      result.close()
    except:
      discard
    raise getCurrentException()

template withHandle*(pool: CurlPool, handle, body) =
  block:
    let handle = pool.borrow()
    try:
      body
    finally:
      pool.recycle(handle)

{.push stackTrace: off.}

proc curlWriteFn(
  buffer: cstring,
  size: int,
  count: int,
  outstream: pointer
): int {.cdecl.} =
  let
    outbuf = cast[ptr StringWrap](outstream)
    i = outbuf.str.len
  outbuf.str.setLen(outbuf.str.len + count)
  copyMem(outbuf.str[i].addr, buffer, count)
  result = size * count

{.pop.}

proc makeRequest*(
  curl: PCurl,
  verb: string,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  result.request.verb = verb
  result.request.url = url

  var strings: seq[string]
  strings.add url
  strings.add verb.toUpperAscii()
  for (k, v) in headers:
    strings.add k & ": " & v

  discard curl.easy_setopt(OPT_URL, strings[0].cstring)
  discard curl.easy_setopt(OPT_CUSTOMREQUEST, strings[1].cstring)
  discard curl.easy_setopt(OPT_TIMEOUT, timeout.int)

  # Create the Pslist for passing headers to curl manually. This is to
  # avoid needing to call slist_free_all which creates problems
  var slists: seq[Slist]
  for i, header in headers:
    slists.add Slist(data: strings[2 + i].cstring, next: nil)
  # Do this in two passes so the slists index addresses are stable
  var headerList: Pslist
  for i, header in headers:
    if i == 0:
      headerList = slists[0].addr
    else:
      var tail = headerList
      while tail.next != nil:
        tail = tail.next
      tail.next = slists[i].addr

  discard curl.easy_setopt(OPT_HTTPHEADER, headerList)

  if cmpIgnoreCase(verb, "HEAD") == 0:
    discard curl.easy_setopt(OPT_NOBODY, 1)
  elif cmpIgnoreCase(verb, "POST") == 0 or body.len > 0:
    discard curl.easy_setopt(OPT_POSTFIELDSIZE, body.len)
    if body.len > 0:
      discard curl.easy_setopt(OPT_POSTFIELDS, body[0].unsafeAddr)

  # Setup writers
  var headerWrap, bodyWrap: StringWrap
  discard curl.easy_setopt(OPT_WRITEDATA, bodyWrap.addr)
  discard curl.easy_setopt(OPT_WRITEFUNCTION, curlWriteFn)
  discard curl.easy_setopt(OPT_HEADERDATA, headerWrap.addr)
  discard curl.easy_setopt(OPT_HEADERFUNCTION, curlWriteFn)

  # Follow up to 10 redirects
  discard curl.easy_setopt(OPT_FOLLOWLOCATION, 1)
  discard curl.easy_setopt(OPT_MAXREDIRS, 10)

  # https://curl.se/libcurl/c/threadsafe.html
  discard curl.easy_setopt(OPT_NOSIGNAL, 1)

  when defined(windows):
    # CURLOPT_SSL_OPTIONS, CURLSSLOPT_NATIVE_CA
    discard curl.easy_setopt(cast[libcurl.Option](216), 1 shl 4)
  else:
    let alreadyHasPendingSIGPIPE = block:
      var pending: Sigset
      discard sigemptyset(pending)
      discard sigpending(pending)
      sigismember(pending, SIGPIPE) != 0

    var oldSet, empty: Sigset
    discard sigemptyset(oldSet)
    discard sigemptyset(empty)
    discard pthread_sigmask(SIG_BLOCK, empty, oldSet) # Read current

    var newSet = oldSet
    discard sigaddset(newSet, SIGPIPE)
    discard pthread_sigmask(SIG_BLOCK, newSet, oldSet) # Block SIGPIPE

  try:
    let ret = curl.easy_perform()
    if ret == E_OK:
      # This avoids a SIGSEGV on Mac with -d:release and a memory leak on Linux
      let tmp4 = allocShared0(4)
      discard curl.easy_getinfo(INFO_RESPONSE_CODE, tmp4)
      var httpCode: uint32
      copyMem(httpCode.addr, tmp4, 4)
      deallocShared(tmp4)
      result.code = httpCode.int
      let tmpcstring = cast[ptr cstring](allocShared0(sizeof(cstring)))
      discard curl.easy_getinfo(INFO_EFFECTIVE_URL, tmpcstring)
      result.url = $tmpcstring[]
      deallocShared(tmpcstring)
      addHeaders(result.headers, headerWrap.str)
      result.body = move bodyWrap.str
      if result.headers["Content-Encoding"] == "gzip":
        result.body = uncompress(result.body, dfGzip)
    else:
      raise newException(
        CatchableError,
        $easy_strerror(ret) & ' ' & verb & ' ' & url
      )
  finally:
    curl.easy_reset()

  when not defined(windows):
    if not alreadyHasPendingSIGPIPE:
      var sigPipeMask: Sigset
      discard sigemptyset(sigPipeMask)
      discard sigaddset(sigPipeMask, SIGPIPE)

      var pending: Sigset
      while true:
        discard sigemptyset(pending)
        discard sigpending(pending)
        if sigismember(pending, SIGPIPE) > 0:
          var sig: cint
          discard sigwait(sigPipeMask, sig)
        else:
          break

    discard pthread_sigmask(SIG_SETMASK, oldSet, empty)

proc get*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  timeout: float32 = 60
): Response =
  curl.makeRequest("GET", url, headers, "", timeout)

proc post*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  curl.makeRequest("POST", url, headers, body, timeout)

proc put*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  curl.makeRequest("PUT", url, headers, body, timeout)

proc patch*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  curl.makeRequest("PATCH", url, headers, body, timeout)

proc delete*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  timeout: float32 = 60
): Response =
  curl.makeRequest("DELETE", url, headers, "", timeout)

proc head*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  timeout: float32 = 60
): Response =
  curl.makeRequest("HEAD", url, headers, "", timeout)

proc get*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("GET", url, headers, "", timeout)

proc post*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("POST", url, headers, body, timeout)

proc put*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("PUT", url, headers, body, timeout)

proc patch*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  body: openarray[char] = "".toOpenArray(0, -1),
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("PATCH", url, headers, body, timeout)

proc delete*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("DELETE", url, headers, "", timeout)

proc head*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("HEAD", url, headers, "", timeout)
