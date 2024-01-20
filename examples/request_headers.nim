import curly

let curl = newCurly()

var headers: HttpHeaders
headers["Accept-Encoding"] = "gzip"

# Blocks until the request completes
let response = curl.get(
  "https://en.wikipedia.org/wiki/Special:Random",
  headers,
  timeout = 10
)

echo response.code
echo response.url
