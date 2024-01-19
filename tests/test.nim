import curly, std/typetraits

const asdf = "https://eafeafaef.localhost.com"

block:
  let curlPool = newCurlPool(3)

  curlPool.withHandle curl:
    let response = curl.get("https://www.google.com")
    doAssert response.code == 200
    doAssert response.headers.len > 0
    doAssert response.body.len > 0

  curlPool.withHandle curl:
    let response = curl.head("https://www.google.com")
    doAssert response.code == 200
    doAssert response.headers.len > 0
    doAssert response.body.len == 0

  doAssertRaises CatchableError:
    echo curlPool.get(asdf)

  curlPool.close()

# block:
#   let curl = newPrototype()

#   var headers: HttpHeaders
#   headers["Accept-Encoding"] = "gzip"

#   let getResponse = curl.get("https://www.google.com", headers)
#   doAssert getResponse.code == 200
#   doAssert getResponse.headers.len > 0
#   doAssert getResponse.body.len > 0

#   let headResponse = curl.head("https://www.google.com")
#   doAssert headResponse.code == 200
#   doAssert getResponse.headers.len > 0
#   doAssert headResponse.body.len == 0

#   doAssertRaises CatchableError:
#     discard curl.get(asdf)

#   curl.close()

# block:
#   let curl = newPrototype()

#   var batch: RequestBatch
#   batch.get("https://www.microsoft.com")
#   batch.get(asdf)
#   batch.get("https://news.ycombinator.com/")

#   echo batch.len

#   let x = curl.makeRequests(batch)

#   doAssert x[0].error == ""
#   doAssert x[1].error != ""
#   doAssert x[2].error == ""

#   doAssert x[0].response.code == 200
#   doAssert x[2].response.code == 200

#   doAssert x[0].response.headers.len > 0
#   doAssert x[2].response.headers.len > 0

#   doAssert x[0].response.body.len > 0
#   doAssert x[2].response.body.len > 0

#   for i, (response, error) in x:
#     echo batch[i].verb, ' ', batch[i].url, " => ", response.code

#   curl.close()
