# Curly

`nimble install curly`

![Github Actions](https://github.com/guzba/curly/workflows/Github%20Actions/badge.svg)

[API reference](https://guzba.github.io/curly/)

Curly is an efficient thread-ready parallel HTTP client built on top of libcurl.

With Curly you can run one or multiple HTTP requests in parallel while either only blocking the calling thread or not blocking at all.

Some highlights are:

* Automatic TCP connection re-use (especially valuable for HTTPS connections).
* Uses HTTP/2 multiplexing when possible (multiple requests in-flight on one TCP connection).
* Any number of threads can start any number of requests and choose their blocking / nonblocking behavior.
* Gzip'ed response bodies are transparently uncompressed.

By choosing what blocks and doesn't block, you can manage your program's control flow however makes sense for you.

## Examples

NOTE! While these examples include `let curl = newCurl()`, it is strongly suggested that you reuse a single or small number of long-lived Curly instances instead of creating new instances frequently.

### A simple request
```nim
let curl = newCurly()

let response = curl.post("https://...", headers, body) # blocks until complete
```

### Multiple requests in parallel
```nim
let curl = newCurly()

var batch: RequestBatch
batch.post("https://...", headers, body)
batch.get("https://...")

for (response, error) in curl.makeRequests(batch): # blocks until all are complete
  if error == "":
    echo response.code
  else:
    echo error
```

### A single non-blocking request
```nim
let curl = newCurly()

curl.startRequest("GET", "https://...") # doesn't block

# do whatever
```

### Multiple non-blocking requests
```nim
let curl = newCurly()

var batch: RequestBatch
batch.get(url1)
batch.get(url2)
batch.get(url3)
batch.get(url4)

curl.startRequests(batch) # doesn't block

# do whatever
```

### Handle responses to non-blocking requests by waiting for them
```nim
let (response, error) = curl.waitForResponse() # blocks until a request is complete
if error == "":
  echo response.code
else:
  echo error
```

### Handle responses to non-blocking requests by polling for them
```nim
let answer = curl.pollForResponse() # checks if a request has completed
if answer.isSome:
  if answer.get.error == "":
    echo answer.get.response.code
  else:
    echo answer.get.error
```

Check out the [examples/](https://github.com/guzba/curly/tree/master/examples) folder for examples using Curly.

## Configuration

When you create a Curly instance, you can optionally specify `maxInFlight` which will let you control the maximum HTTP requests that will be actively running at any time. This means you can queue 100,000 requests and know that only say 100 of them will be in-flight at a time.

## Queue management

Since `startRequests` can add any number of HTTP requests to a queue, and since HTTP requests can block for a long time, it is really easy to find yourself with an ever-growing queue and run out of memory. This is no good.

You can ask a Curly instance how long its queue is (`queueLen`) and if you think that is too long, you can call `clearQueue`. Clearing the queue will unblock all threads waiting for responses and each queued request will have an error stating it was canceled.

## A key difference from Nim's std/httpclient

When using Nim's std/httpclient, it is expected that you use a new HttpClient or AsyncHttpClient for each request. This is both not needed and a bad idea with Curly.

This is because Curly reuses connections instead of setting them up and tearing them down for each request. A Curly instance should be long-lived, probably for the entire process lifespan.

It is a great starting point to simply have `let curl* = newCurly()` at the top of your program and use it everywhere for any number of requests from any number of threads.

## Production tested

I have been using Curly in a production web server to make 20k+ HTTPS requests per minute on a tiny VM for a while now without any trouble.

Both the blocking and non-blocking Curly APIs are used and confirmed working in a very multi-threaded production environment.

## Platform support

Curly should work out-of-the-box on Linux and Mac.

On Windows you'll need to grab the latest libcurl DLL from https://curl.se/windows/, rename it to libcurl.dll, and put it in the same directory as your executable.
