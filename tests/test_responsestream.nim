import curly

let curl = newCurly()

let stream = curl.request("GET", "https://www.google.com")

echo stream.code
echo stream.headers

while true:
  var buffer: string
  let bytesRead = stream.read(buffer)
  if bytesRead == 0:
    break
  echo buffer

echo "DONE"
