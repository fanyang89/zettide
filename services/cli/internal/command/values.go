package command

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"math"
	"strings"
)

func parseFixedBytes(value string, size int, flagName string) ([]byte, error) {
	if value == "" {
		return nil, fmt.Errorf("--%s is required", flagName)
	}
	normalized := strings.ReplaceAll(value, "-", "")
	decoded, err := hex.DecodeString(normalized)
	if err != nil {
		return nil, fmt.Errorf("--%s must be hexadecimal or UUID text: %w", flagName, err)
	}
	if len(decoded) != size {
		return nil, fmt.Errorf("--%s must encode exactly %d bytes (got %d)", flagName, size, len(decoded))
	}
	allZero := true
	for _, b := range decoded {
		if b != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return nil, fmt.Errorf("--%s must not be all zero", flagName)
	}
	return decoded, nil
}

func parseUUIDv7(value, flagName string) ([]byte, error) {
	decoded, err := parseFixedBytes(value, 16, flagName)
	if err != nil {
		return nil, err
	}
	if decoded[6]&0xf0 != 0x70 || decoded[8]&0xc0 != 0x80 {
		return nil, fmt.Errorf("--%s must be a UUIDv7", flagName)
	}
	return decoded, nil
}

func validateUUIDv7Text(value, flagName string) error {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return fmt.Errorf("--%s must be canonical UUID text", flagName)
	}
	_, err := parseUUIDv7(value, flagName)
	return err
}

func parsePageToken(value string) ([]byte, error) {
	if value == "" {
		return nil, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("--page-token must be base64: %w", err)
	}
	return decoded, nil
}

func checkedUint32(value uint64, flagName string) (uint32, error) {
	if value > math.MaxUint32 {
		return 0, fmt.Errorf("--%s exceeds uint32", flagName)
	}
	return uint32(value), nil
}

func checkedUint16(value uint64, flagName string) (uint32, error) {
	if value > math.MaxUint16 {
		return 0, fmt.Errorf("--%s exceeds uint16", flagName)
	}
	return uint32(value), nil
}

func checkedPageSize(value uint64) (uint32, error) {
	const maxPageSize = 1000
	if value > maxPageSize {
		return 0, fmt.Errorf("--page-size must not exceed %d", maxPageSize)
	}
	return uint32(value), nil
}

func validateVolumeSize(value uint64) error {
	const (
		blockSize     = uint64(4096)
		minVolumeSize = uint64(256 * 1024)
		maxVolumeSize = uint64(math.MaxUint32) * blockSize
	)
	if value < minVolumeSize {
		return fmt.Errorf("--size-bytes must be at least %d", minVolumeSize)
	}
	if value > maxVolumeSize {
		return fmt.Errorf("--size-bytes must not exceed %d", maxVolumeSize)
	}
	if value%blockSize != 0 {
		return fmt.Errorf("--size-bytes must be aligned to %d bytes", blockSize)
	}
	return nil
}

func requestID(value string) (string, error) {
	if value != "" {
		return value, nil
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", fmt.Errorf("generate request ID: %w", err)
	}
	return "zettidectl-" + hex.EncodeToString(random[:]), nil
}

func requireExactlyOne(first, firstName, second, secondName string) error {
	if (first == "") == (second == "") {
		return fmt.Errorf("exactly one of --%s or --%s is required", firstName, secondName)
	}
	return nil
}
