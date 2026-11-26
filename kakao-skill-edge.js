// CloudFront viewer-request function (money-ledger#314). Only POST /kakao/skill may pass; anything
// else is answered here with a 404 and never reaches the server. The app checks the secret header
// and the user allowlist itself.
function handler(event) {
  var request = event.request;
  if (request.method === 'POST' && request.uri === '/kakao/skill') {
    return request;
  }
  return {
    statusCode: 404,
    statusDescription: 'Not Found',
    headers: { 'cache-control': { value: 'no-store' } },
  };
}
