import curly

let curl = newCurly()

# let stream = curl.request("GET", "https://sse.dev/test", timeout = 5)
let stream = curl.request("GET", "https://www.google.com")

echo stream.code
echo stream.headers

try:
  while true:
    var buffer: string
    let bytesRead = stream.read(buffer)
    if bytesRead == 0:
      break
    echo buffer
finally:
  stream.close()

echo "DONE"
