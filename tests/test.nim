import curly

let curlPool = newCurlPool(3)

curlPool.withHandle curl:
  let response = curl.get("https://www.google.com")
  doAssert response.code == 200
  doAssert response.body.len > 0
