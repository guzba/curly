import curly

let pool = newCurlPool(3)
pool.withHandle curl:
  let response = curl.get("https://www.google.com")
  doAssert response.code == 200
  doAssert response.body.len > 0
