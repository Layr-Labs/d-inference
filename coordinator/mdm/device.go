package mdm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// DeviceInfo from MicroMDM's device list.
type DeviceInfo struct {
	SerialNumber     string `json:"serial_number"`
	UDID             string `json:"udid"`
	EnrollmentStatus bool   `json:"enrollment_status"`
	LastSeen         string `json:"last_seen"`
}

// LookupDevice checks if a device with the given serial number is enrolled.
func (c *Client) LookupDevice(ctx context.Context, serialNumber string) (*DeviceInfo, error) {
	body, _ := json.Marshal(map[string]string{"serial_number": serialNumber})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/devices", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth("micromdm", c.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("mdm device lookup failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("mdm device lookup returned %d", resp.StatusCode)
	}

	var result struct {
		Devices []DeviceInfo `json:"devices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("mdm device lookup decode failed: %w", err)
	}

	for _, d := range result.Devices {
		if d.SerialNumber == serialNumber {
			return &d, nil
		}
	}

	return nil, nil // not found
}
