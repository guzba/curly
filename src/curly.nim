import waterpark, libcurl, std/sequtils, std/strutils, webby, zippy

block:
  let ret = global_init(GLOBAL_DEFAULT)
  if ret != E_OK:
    raise newException(Defect, $easy_strerror(ret))

type
  CurlPool* = object
    pool: Pool[PCurl]

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
  let entries = toSeq(pool.pool.items)
  for entry in entries:
    entry.easy_cleanup()
    pool.pool.delete(entry)
  pool.pool.close()

proc newCurlPool*(size: int): CurlPool =
  ## Creates a new thead-safe pool of libcurl handles.
  if size <= 0:
    raise newException(CatchableError, "Invalid pool size")
  result.pool = newPool[PCurl]()
  try:
    for _ in 0 ..< size:
      result.pool.recycle(easy_init())
  except:
    try:
      result.close()
    except:
      discard
    raise getCurrentException()

proc borrow*(pool: CurlPool): PCurl {.inline, raises: [], gcsafe.} =
  pool.pool.borrow()

proc recycle*(pool: CurlPool, handle: PCurl) {.inline, raises: [], gcsafe.} =
  pool.pool.recycle(handle)

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
  body: sink string = "",
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

  if verb.toUpperAscii() == "HEAD":
    discard curl.easy_setopt(OPT_NOBODY, 1)
  elif verb.toUpperAscii() == "POST" or body.len > 0:
    discard curl.easy_setopt(OPT_POSTFIELDSIZE, body.len)
    discard curl.easy_setopt(OPT_POSTFIELDS, body.cstring)

  # Setup writers
  var headerWrap, bodyWrap: StringWrap
  discard curl.easy_setopt(OPT_WRITEDATA, bodyWrap.addr)
  discard curl.easy_setopt(OPT_WRITEFUNCTION, curlWriteFn)
  discard curl.easy_setopt(OPT_HEADERDATA, headerWrap.addr)
  discard curl.easy_setopt(OPT_HEADERFUNCTION, curlWriteFn)

  # Follow up to 10 redirects
  discard curl.easy_setopt(OPT_FOLLOWLOCATION, 1)
  discard curl.easy_setopt(OPT_MAXREDIRS, 10)

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
      raise newException(CatchableError, $easy_strerror(ret))
  finally:
    curl.easy_reset()

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
  body: sink string = "",
  timeout: float32 = 60
): Response =
  curl.makeRequest("POST", url, headers, body, timeout)

proc put*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  body: sink string = "",
  timeout: float32 = 60
): Response =
  curl.makeRequest("PUT", url, headers, body, timeout)

proc patch*(
  curl: PCurl,
  url: string,
  headers = emptyHttpHeaders(),
  body: sink string = "",
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
  body: sink string = "",
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("POST", url, headers, body, timeout)

proc put*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  body: sink string = "",
  timeout: float32 = 60
): Response =
  pool.withHandle curl:
    result = curl.makeRequest("PUT", url, headers, body, timeout)

proc patch*(
  pool: CurlPool,
  url: string,
  headers = emptyHttpHeaders(),
  body: sink string = "",
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
