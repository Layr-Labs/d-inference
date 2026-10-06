// Package mediawork estimates native media prompt work from bounded container
// metadata. It never decodes pixels/audio, fetches URLs, or retains request data.
package mediawork

import (
	"encoding/json"
	"math"
)

// Profile is immutable processor configuration from a verified model artifact.
// A model name or caller-supplied dimensions cannot create a profile.
type Profile struct {
	patch, merge, temporal                             int
	imageMin, imageMax, videoMin, videoMax, videoTotal int
	fps                                                float64
	minFrames, maxFrames                               int
	audio                                              bool
}

func FromConfig(data []byte) *Profile {
	if len(data) == 0 || len(data) > 1<<20 {
		return nil
	}
	var c struct {
		ModelType string `json:"model_type"`
		Processor struct {
			Patch        int     `json:"patch_size"`
			Merge        int     `json:"merge_size"`
			Temporal     int     `json:"temporal_patch_size"`
			Compression  int     `json:"temporal_compression_ratio"`
			ImageMin     int     `json:"image_min_pixels"`
			ImageMax     int     `json:"image_max_pixels"`
			VideoMin     int     `json:"video_min_pixels"`
			VideoMax     int     `json:"video_max_pixels"`
			VideoTotal   int     `json:"video_total_max_pixels"`
			FPS          float64 `json:"fps"`
			MinFrames    int     `json:"min_frames"`
			MaxFrames    int     `json:"max_frames"`
			Rope         string  `json:"rope_type"`
			Timestamps   bool    `json:"use_video_timestamps"`
			PerGrid      bool    `json:"use_per_grid_t_timestamps"`
			AudioRate    int     `json:"audio_sampling_rate"`
			AudioHop     int     `json:"audio_hop_length"`
			AudioStride  int     `json:"audio_stride_size"`
			AudioPool    int     `json:"audio_avg_pooler"`
			AudioGroup   int     `json:"audio_group_size"`
			AudioSegment int     `json:"audio_segment_size"`
		} `json:"processor_config"`
		Vision struct {
			Patch    int `json:"patch_size"`
			Merge    int `json:"spatial_merge_size"`
			Temporal int `json:"temporal_patch_size"`
		} `json:"vision_config"`
	}
	if json.Unmarshal(data, &c) != nil || c.ModelType != "mimo_v2" {
		return nil
	}
	s := c.Processor
	if s.Rope != "rope" || !s.Timestamps || s.PerGrid || s.Compression != 1 ||
		s.Patch != c.Vision.Patch || s.Merge != c.Vision.Merge || s.Temporal != c.Vision.Temporal {
		return nil
	}
	if s.Patch <= 0 || s.Patch > 128 || s.Merge <= 0 || s.Merge > 16 || s.Temporal <= 0 || s.Temporal > 16 {
		return nil
	}
	for _, n := range []int{s.ImageMin, s.ImageMax, s.VideoMin, s.VideoMax, s.VideoTotal} {
		if n <= 0 || n > 1<<30 {
			return nil
		}
	}
	if s.ImageMin > s.ImageMax || s.VideoMin > s.VideoMax {
		return nil
	}
	// Native decoder's zero/null values use these same defaults.
	if s.FPS == 0 {
		s.FPS = 2
	}
	if s.MinFrames == 0 {
		s.MinFrames = 8
	}
	if s.MaxFrames == 0 {
		s.MaxFrames = 256
	}
	if math.IsNaN(s.FPS) || math.IsInf(s.FPS, 0) || s.FPS <= 0 || s.FPS > 1000 ||
		s.MinFrames <= 0 || s.MaxFrames > 100_000 || (s.MinFrames+1)/2*2 > s.MaxFrames/2*2 {
		return nil
	}
	return &Profile{patch: s.Patch, merge: s.Merge, temporal: s.Temporal,
		imageMin: s.ImageMin, imageMax: s.ImageMax, videoMin: s.VideoMin, videoMax: s.VideoMax, videoTotal: s.VideoTotal,
		fps: s.FPS, minFrames: s.MinFrames, maxFrames: s.MaxFrames,
		audio: s.AudioRate == 24000 && s.AudioHop == 240 && s.AudioStride == 2 && s.AudioPool == 2 && s.AudioGroup == 4 && s.AudioSegment == 6000}
}
