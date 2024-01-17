import curly, std/typetraits

const asdf = "https://eafeafaef.localhost.com"

block:
  let curlPool = newCurlPool(3)

  curlPool.withHandle curl:
    let response = curl.get("https://www.google.com")
    doAssert response.code == 200
    doAssert response.body.len > 0

  curlPool.withHandle curl:
    let response = curl.head("https://www.google.com")
    doAssert response.code == 200
    doAssert response.body.len == 0

  doAssertRaises CatchableError:
    echo curlPool.get(asdf)

# block:
#   let curl = newPrototype()

#   var headers: HttpHeaders
#   headers["Accept-Encoding"] = "gzip"

#   let getResponse = curl.get("https://www.google.com", headers)
#   doAssert getResponse.code == 200
#   doAssert getResponse.body.len > 0

#   let headResponse = curl.head("https://www.google.com")
#   doAssert headResponse.code == 200
#   doAssert headResponse.body.len == 0

#   doAssertRaises CatchableError:
#     discard curl.get(asdf)
