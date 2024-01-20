import curly

let curl = newCurly()

var batch: RequestBatch
for i in 0 ..< 10: # Get 10 random Wikipedia articles
  batch.get("https://en.wikipedia.org/wiki/Special:Random")

# Blocks until the requests completes
# Responses are in the same order as the requests were added to the batch
for (response, error) in curl.makeRequests(batch):
  if error == "":
    echo response.code, ' ', response.url
  else:
    echo error
