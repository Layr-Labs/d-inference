package mdm

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/google/uuid"
)

const maxMDMResponseBytes = 1 << 20

func requireMDMStatus(resp *http.Response, operation string, allowed ...int) error {
	for _, status := range allowed {
		if resp.StatusCode == status {
			return nil
		}
	}
	body, _ := readMDMBody(resp.Body)
	detail := strings.TrimSpace(string(body))
	if detail == "" {
		detail = http.StatusText(resp.StatusCode)
	}
	return fmt.Errorf("%s returned HTTP %d: %s", operation, resp.StatusCode, detail)
}

func decodeMDMJSON(resp *http.Response, operation string, target any) error {
	body, err := readMDMBody(resp.Body)
	if err != nil {
		return fmt.Errorf("%s response read failed: %w", operation, err)
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return fmt.Errorf("%s response body is empty", operation)
	}
	if err := json.Unmarshal(body, target); err != nil {
		return fmt.Errorf("%s response schema invalid: %w", operation, err)
	}
	return nil
}

func readMDMBody(body io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(body, maxMDMResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxMDMResponseBytes {
		return nil, fmt.Errorf("response exceeds %d bytes", maxMDMResponseBytes)
	}
	return data, nil
}

func decodeDeviceLookupResponse(resp *http.Response) ([]DeviceInfo, error) {
	var envelope struct {
		Devices json.RawMessage `json:"devices"`
	}
	if err := decodeMDMJSON(resp, "mdm device lookup", &envelope); err != nil {
		return nil, err
	}
	if len(envelope.Devices) == 0 || bytes.Equal(bytes.TrimSpace(envelope.Devices), []byte("null")) {
		return nil, fmt.Errorf("mdm device lookup response schema invalid: devices array is required")
	}

	var devices []struct {
		SerialNumber     *string `json:"serial_number"`
		UDID             *string `json:"udid"`
		EnrollmentStatus *bool   `json:"enrollment_status"`
		LastSeen         string  `json:"last_seen"`
	}
	if err := json.Unmarshal(envelope.Devices, &devices); err != nil {
		return nil, fmt.Errorf("mdm device lookup response schema invalid: devices: %w", err)
	}

	result := make([]DeviceInfo, 0, len(devices))
	for i, device := range devices {
		if device.SerialNumber == nil || strings.TrimSpace(*device.SerialNumber) == "" {
			return nil, fmt.Errorf("mdm device lookup response schema invalid: devices[%d].serial_number is required", i)
		}
		if device.UDID == nil || strings.TrimSpace(*device.UDID) == "" {
			return nil, fmt.Errorf("mdm device lookup response schema invalid: devices[%d].udid is required", i)
		}
		if device.EnrollmentStatus == nil {
			return nil, fmt.Errorf("mdm device lookup response schema invalid: devices[%d].enrollment_status is required", i)
		}
		result = append(result, DeviceInfo{
			SerialNumber:     *device.SerialNumber,
			UDID:             *device.UDID,
			EnrollmentStatus: *device.EnrollmentStatus,
			LastSeen:         device.LastSeen,
		})
	}
	return result, nil
}

func decodeCommandResponse(resp *http.Response) (string, error) {
	var envelope struct {
		Payload *struct {
			CommandUUID string `json:"command_uuid"`
		} `json:"payload"`
	}
	if err := decodeMDMJSON(resp, "mdm command", &envelope); err != nil {
		return "", err
	}
	if envelope.Payload == nil {
		return "", fmt.Errorf("mdm command response schema invalid: payload is required")
	}
	commandUUID := strings.TrimSpace(envelope.Payload.CommandUUID)
	if _, err := uuid.Parse(commandUUID); err != nil {
		return "", fmt.Errorf("mdm command response schema invalid: payload.command_uuid is not a UUID")
	}
	return commandUUID, nil
}

func validateRawCommandResponse(
	resp *http.Response,
	udid string,
	commandUUID string,
	requestType string,
) error {
	var envelope struct {
		Payload *struct {
			UDID        string `json:"udid"`
			CommandUUID string `json:"command_uuid"`
			Command     *struct {
				RequestType string `json:"request_type"`
			} `json:"command"`
		} `json:"payload"`
	}
	if err := decodeMDMJSON(resp, "mdm raw command", &envelope); err != nil {
		return err
	}
	if envelope.Payload == nil || envelope.Payload.Command == nil {
		return fmt.Errorf("mdm raw command response schema invalid: payload and payload.command are required")
	}
	if envelope.Payload.UDID != udid {
		return fmt.Errorf("mdm raw command response schema invalid: payload.udid mismatch")
	}
	if envelope.Payload.CommandUUID != commandUUID {
		return fmt.Errorf("mdm raw command response schema invalid: payload.command_uuid mismatch")
	}
	if envelope.Payload.Command.RequestType != requestType {
		return fmt.Errorf("mdm raw command response schema invalid: payload.command.request_type mismatch")
	}
	return nil
}

func validatePushResponse(resp *http.Response) error {
	var result struct {
		Status string `json:"status"`
		ID     string `json:"push_notification_id"`
	}
	if err := decodeMDMJSON(resp, "mdm push", &result); err != nil {
		return err
	}
	if result.Status != "success" {
		return fmt.Errorf("mdm push response schema invalid: status is %q", result.Status)
	}
	if strings.TrimSpace(result.ID) == "" {
		return fmt.Errorf("mdm push response schema invalid: push_notification_id is required")
	}
	return nil
}
