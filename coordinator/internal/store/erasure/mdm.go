package erasure

import (
	"sort"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// DeviceRow is one provider_trust_reuse or provider_verification_jobs row:
// the Secure Enclave key and the device serial and UDID that it holds.
type DeviceRow struct {
	SEKey, Serial, UDID string
}

// MDMDevices lists the Macs to remove from MicroMDM by hand after the scrub.
// It uses the ownership rules of the scrub:
//
//   - rows holds the trust and verification rows of k.SEKeys, which the scrub
//     deletes, and every other row with one of their serials or UDIDs or a
//     serial of k.Serials. k.SEKeys has the current and historical Secure
//     Enclave keys of the account (providers, legacy_se aliases and
//     erasure_se_owners) without the keys that another account shares.
//   - k.Serials adds each serial of the account's providers and sessions that
//     no trust or verification row holds.
//
// A device is left out when another account can still use it: a row of a
// key that is not in k.SEKeys holds its serial or UDID, its mda_serial alias
// is shared (k.SharedMDADigests), or serialsElsewhere (serials of provider
// rows and sessions of other accounts that are not erased) holds its serial.
func (k *Keys) MDMDevices(rows []DeviceRow, serialsElsewhere []string) []store.ErasureMDMDevice {
	own := map[string]bool{}
	for _, key := range k.SEKeys {
		own[key] = true
	}
	shared := map[string]bool{}
	for _, d := range k.SharedMDADigests {
		shared[d] = true
	}
	otherSerial, otherUDID := map[string]bool{}, map[string]bool{}
	for _, s := range serialsElsewhere {
		otherSerial[s] = true
	}
	devices := map[store.ErasureMDMDevice]bool{}
	for _, r := range rows {
		if own[r.SEKey] {
			devices[store.ErasureMDMDevice{Serial: r.Serial, UDID: r.UDID}] = true
			continue
		}
		otherSerial[r.Serial], otherUDID[r.UDID] = true, true
	}
	for _, s := range k.Serials {
		devices[store.ErasureMDMDevice{Serial: s}] = true
	}
	delete(otherSerial, "")
	delete(otherUDID, "")
	withUDID, withSerial := map[string]bool{}, map[string]bool{}
	for d := range devices {
		if d.Serial != "" && d.UDID != "" {
			withUDID[d.Serial], withSerial[d.UDID] = true, true
		}
	}
	out := []store.ErasureMDMDevice{}
	for d := range devices {
		switch {
		case d.Serial == "" && d.UDID == "":
		case otherSerial[d.Serial], otherUDID[d.UDID]:
		case d.Serial != "" && shared[MDASerialDigest(d.Serial)]:
		case d.UDID == "" && withUDID[d.Serial], d.Serial == "" && withSerial[d.UDID]:
		default:
			out = append(out, d)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Serial != out[j].Serial {
			return out[i].Serial < out[j].Serial
		}
		return out[i].UDID < out[j].UDID
	})
	return out
}

// MDMSerials are the serials whose other holders MDMDevices needs: those of
// k.Serials and of the rows of k.SEKeys.
func (k *Keys) MDMSerials(rows []DeviceRow) []string {
	own := map[string]bool{}
	for _, key := range k.SEKeys {
		own[key] = true
	}
	serials := append([]string(nil), k.Serials...)
	for _, r := range rows {
		if own[r.SEKey] {
			serials = append(serials, r.Serial)
		}
	}
	return SortedUnique(serials)
}
