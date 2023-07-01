import curly, std/times, httpclient

## A demo of why reusing HTTPS connections is important.
##
## nim c -d:release -d:ssl -r examples/keepalive.nim

block:
  let curl = newCurlPool(1)

  let start = epochTime()

  for _ in 0 ..< 10:
    discard curl.get("https://www.google.com")

  echo epochTime() - start

block:
  let start = epochTime()

  for _ in 0 ..< 10:
    var client = newHttpClient()
    discard client.getContent("https://www.google.com")

  echo epochTime() - start
