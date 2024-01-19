import curly

const badurl = "https://eafeafaef.localhost.com"

block:
  let curlPool = newCurlPool(3)

  curlPool.withHandle curl:
    let response = curl.get("https://www.google.com")
    doAssert response.code == 200
    doAssert response.headers.len > 0
    doAssert response.body.len > 0

    doAssert response.request.verb == "GET"
    doAssert response.request.url == "https://www.google.com"
    doAssert response.url == "https://www.google.com/"

  curlPool.withHandle curl:
    let response = curl.head("https://www.google.com")
    doAssert response.code == 200
    doAssert response.headers.len > 0
    doAssert response.body.len == 0

  doAssertRaises CatchableError:
    echo curlPool.get(badurl)

  curlPool.close()

when defined(curlyPrototype):
  import std/os

  block:
    let curl = newPrototype()

    var headers: HttpHeaders
    headers["Accept-Encoding"] = "gzip"

    let getResponse = curl.get("https://www.google.com", headers)
    doAssert getResponse.code == 200
    doAssert getResponse.headers.len > 0
    doAssert getResponse.body.len > 0

    doAssert getResponse.request.verb == "GET"
    doAssert getResponse.request.url == "https://www.google.com"
    doAssert getResponse.url == "https://www.google.com/"

    let headResponse = curl.head("https://www.google.com")
    doAssert headResponse.code == 200
    doAssert getResponse.headers.len > 0
    doAssert headResponse.body.len == 0

    doAssertRaises CatchableError:
      discard curl.get(badurl)

    curl.close()

  block:
    let curl = newPrototype()

    var batch: RequestBatch
    batch.get("https://www.microsoft.com")
    batch.get(badurl, tag = "tag_test")
    batch.get("https://news.ycombinator.com/")

    echo batch.len

    let rb = curl.makeRequests(batch)

    doAssert rb[0].error == ""
    doAssert rb[1].error != ""
    doAssert rb[2].error == ""

    doAssert rb[0].response.code == 200
    doAssert rb[2].response.code == 200

    doAssert rb[0].response.headers.len > 0
    doAssert rb[2].response.headers.len > 0

    doAssert rb[0].response.body.len > 0
    doAssert rb[2].response.body.len > 0

    doAssert rb[2].response.request.verb == "GET"
    doAssert rb[2].response.request.url == "https://news.ycombinator.com/"
    doAssert rb[2].response.url == "https://news.ycombinator.com/"

    doAssert rb[1].response.request.tag == "tag_test"

    for i, (response, error) in rb:
      echo batch[i].verb, ' ', batch[i].url, " => ", response.code

    doAssert curl.queueLen == 0

    curl.close()

  block:
    let curl = newPrototype(0)

    proc threadProc(curl: Prototype) =
      try:
        discard curl.get(badurl)
      except:
        doAssert getCurrentExceptionMsg() == "Canceled in clearQueue"

    var threads = newSeq[Thread[Prototype]](10)
    for thread in threads.mitems:
      createThread(thread, threadProc, curl)

    while curl.queueLen != threads.len:
      sleep(1)

    curl.clearQueue()

    joinThreads(threads)

  block:
    let curl = newPrototype()

    var batch: RequestBatch
    batch.get("https://www.yahoo.com")
    batch.get(badurl, tag = "tag_test")
    batch.get("https://nim-lang.org")

    curl.startRequests(batch, timeout = 10)

    for i in 0 ..< batch.len:
      let (response, error) = curl.waitForResponse()
      if error == "":
        echo response.request.url
      else:
        echo error

  block:
    let curl = newPrototype(0)

    var batch: RequestBatch
    batch.get(badurl)
    batch.get(badurl)
    batch.get(badurl)
    batch.get(badurl)

    curl.startRequests(batch)

    doAssert curl.queueLen == batch.len

    curl.clearQueue()

    doAssert curl.queueLen == 0

    for i in 0 ..< batch.len:
      let (response, error) = curl.waitForResponse()
      doAssert error == "Canceled in clearQueue"

  block:
    let curl = newPrototype()

    curl.startRequest("GET", badurl, tag = $0)

    var i: int
    while true:
      let (response, error) = curl.waitForResponse()
      doAssert response.request.verb == "GET"
      doAssert response.request.url == badurl
      doAssert response.request.tag == $i
      if i < 10:
        inc i
        curl.startRequest("GET", badurl, tag = $i)

      else:
        break
