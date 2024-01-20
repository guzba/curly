import curly, std/times

let curl = newCurly()

echo "Sequentially request 10 random Wikipedia articles:"
let sequentialStart = epochTime()

for i in 0 ..< 10:
  let response = curl.get("https://en.wikipedia.org/wiki/Special:Random")
  echo response.code, ' ', response.url

let sequentialTime = epochTime() - sequentialStart

echo "Parallel requests for 10 random Wikipedia articles:"

let parallelStart = epochTime()

var batch: RequestBatch
for i in 0 ..< 10: # Get 10 random Wikipedia articles
  batch.get("https://en.wikipedia.org/wiki/Special:Random")

for (response, error) in curl.makeRequests(batch):
  if error == "":
    echo response.code, ' ', response.url
  else:
    echo error

let parallelTime = epochTime() - parallelStart

echo "--"
echo "Sequental requests took ", sequentialTime, " seconds"
echo "Parallel requests took ", parallelTime, " seconds"
