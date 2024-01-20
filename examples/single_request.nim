import curly

let curl = newCurly()

# Blocks until the request completes
let response = curl.get("https://en.wikipedia.org/wiki/Special:Random")

echo response.code
echo response.url
