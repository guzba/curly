import mummy, mummy/routers, curly

## This example shows a basic HTTP server that makes a GET request to
## https://www.google.com and returns the body length every time a request is
## received.
##
## Using a pool of handles here means we can take advantage of Keep-Alive,
## reusing the connection instead of always opening a new one.

let curlPool = newCurlPool(3)

proc handler(request: Request) =
  curlPool.withHandle curl:
    let response = curl.get("https://www.google.com")
    request.respond(200, emptyHttpHeaders(), $response.body.len)

var router: Router
router.get("/", handler)

let server = newServer(router)
echo "Serving on port 8080"
server.serve(Port(8080))
