// CloudFront Functions(viewer-request)。/images/secret.jpg だけを対象に、
// KVS(Key Value Store)に入っている解禁日時(ISO8601, UTC)を過ぎるまで
// 403を返す。runtimeはcloudfront-js-2.0(KVS APIを使うため)が必要。
import cf from "cloudfront";

var kvsHandle = cf.kvs();
var GATED_PATH = "/images/secret.jpg";
var RELEASE_TIME_KEY = "release_time_secret_jpg";

async function handler(event) {
  var request = event.request;

  if (request.uri !== GATED_PATH) {
    return request;
  }

  var releaseTimeStr = "1970-01-01T00:00:00Z";
  try {
    releaseTimeStr = await kvsHandle.get(RELEASE_TIME_KEY);
  } catch (e) {
    // キーが無い場合は未解禁扱い(安全側に倒す)
  }

  var releaseTime = new Date(releaseTimeStr).getTime();
  var now = Date.now();

  if (isNaN(releaseTime) || now < releaseTime) {
    return {
      statusCode: 403,
      statusDescription: "Forbidden",
      headers: {
        "content-type": { value: "text/plain; charset=utf-8" },
      },
      body: {
        encoding: "text",
        data: "This content is not available yet.",
      },
    };
  }

  return request;
}
