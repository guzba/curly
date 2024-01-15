import libcurl, std/strutils, std/locks, std/posix, std/random, webby/httpheaders, zippy

export httpheaders

block:
  let ret = global_init(GLOBAL_DEFAULT)
  if ret != E_OK:
    raise newException(Defect, $easy_strerror(ret))

  let data = version_info(VERSION_NOW)
  if (data.features and VERSION_ASYNCHDNS) == 0:
    echo "Curly warning: libcurl does not have CURL_VERSION_ASYNCHDNS bit set"

type
  CurlPoolObj = object
    handles: seq[PCurl]
    lock: Lock
    cond: Cond
    r: Rand

  CurlPool* = ptr CurlPoolObj

  Response* = object
    code*: int
    headers*: HttpHeaders
    body*: string

  StringWrap = object
    ## As strings are value objects they need
    ## some sort of wrapper to be passed to C.
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
  if size <= 0:
    raise newException(CatchableError, "Invalid pool size")
  # result.pool = newPool[PCurl]()

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
      let tmp = allocShared0(4)
      discard curl.easy_getinfo(INFO_RESPONSE_CODE, tmp)
      var httpCode: uint32
      copyMem(httpCode.addr, tmp, 4)
      deallocShared(tmp)
      result.code = httpCode.int
      for headerLine in headerWrap.str.split("\r\n"):
        let arr = headerLine.split(":", 1)
        if arr.len == 2:
          result.headers.add((arr[0].strip(), arr[1].strip()))
      result.body = move bodyWrap.str
      if result.headers["Content-Encoding"] == "gzip":
        result.body = uncompress(result.body, dfGzip)
    else:
      let msg = $easy_strerror(ret) & " " & verb & " " & url
      raise newException(CatchableError, msg)
  finally:
    curl.easy_reset()

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
        echo "TMP dropping SIGPIPE"
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
