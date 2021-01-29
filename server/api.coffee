apiMethods =
  '/roomNew': (options) ->
    try
      ids = Meteor.call 'roomNew',
        grid: Boolean JSON.parse options.get 'grid'
      status: 200
      json:
        ok: true
        id: ids.room
        url: Meteor.absoluteUrl "/r/#{ids.room}"
    catch e
      status: 500
      json:
        ok: false
        error: "Error creating new room: #{e}"

## Allow CORS for API calls
WebApp.connectHandlers.use '/api', (req, res, next) ->
  res.setHeader 'Access-Control-Allow-Origin', '*'
  next()

WebApp.connectHandlers.use '/api', (req, res, next) ->
  return unless req.method in ['GET', 'POST']
  url = new URL req.url, Meteor.absoluteUrl()
  if Object.prototype.hasOwnProperty.call apiMethods, url.pathname
    result = apiMethods[url.pathname] url.searchParams, req, res, next
  else
    result =
      status: 404
      json:
        ok: false
        error: "Unknown API endpoint: #{url.pathname}"
  unless res.headersSent
    res.writeHead result.status, 'Content-type': 'application/json'
  unless res.writeableEnded
    res.end JSON.stringify result.json
