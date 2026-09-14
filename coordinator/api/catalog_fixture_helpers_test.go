package api

import (
	"strconv"
)

func modelEntriesCacheKey(includeBuilds bool) string {
	return "models:entries:v1:include_builds=" + strconv.FormatBool(includeBuilds)
}

func modelListBodyCacheKey(includeBuilds bool) string {
	return "models:list:v1:include_builds=" + strconv.FormatBool(includeBuilds)
}

const openRouterFeedCacheKey = "models:openrouter:v1"

const huggingFaceIDMetadataKey = "hugging_face_id"

// maxAliasIDLength bounds the public alias id; it appears in URLs, response
// bodies, and SSE chunks, so it must stay short and single-segment.
const maxAliasIDLength = 128
