package globalpayouts

// US account menu and published recipient requirements, verified 2026-09-05.
// New cross-border recipients outside the documented Connect transfer region
// use Global Payouts. Existing ready Connect destinations remain on their rail.
// CN is absent from the live menu; KH and GI have no verified route here.
type Country struct {
	Code       string `json:"code"`
	Name       string `json:"name"`
	Rail       string `json:"rail"`
	Currency   string `json:"currency,omitempty"`
	Capability string `json:"-"`
}

var Countries = []Country{
	{Code: "AL", Name: "Albania", Rail: "global", Currency: "all", Capability: "wire"},
	{Code: "DZ", Name: "Algeria", Rail: "global", Currency: "dzd", Capability: "wire"},
	{Code: "AG", Name: "Antigua and Barbuda", Rail: "global", Currency: "xcd", Capability: "wire"},
	{Code: "AM", Name: "Armenia", Rail: "global", Currency: "amd", Capability: "wire"},
	{Code: "AU", Name: "Australia", Rail: "global", Currency: "aud", Capability: "local"},
	{Code: "AT", Name: "Austria", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "BS", Name: "Bahamas", Rail: "global", Currency: "bsd", Capability: "wire"},
	{Code: "BH", Name: "Bahrain", Rail: "global", Currency: "bhd", Capability: "wire"},
	{Code: "BE", Name: "Belgium", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "BJ", Name: "Benin", Rail: "global", Currency: "xof", Capability: "local"},
	{Code: "BT", Name: "Bhutan", Rail: "global", Currency: "btn", Capability: "wire"},
	{Code: "BA", Name: "Bosnia and Herzegovina", Rail: "global", Currency: "bam", Capability: "wire"},
	{Code: "BW", Name: "Botswana", Rail: "global", Currency: "bwp", Capability: "wire"},
	{Code: "BN", Name: "Brunei", Rail: "global", Currency: "bnd", Capability: "wire"},
	{Code: "BG", Name: "Bulgaria", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "CA", Name: "Canada", Rail: "connect", Currency: "cad", Capability: "local"},
	{Code: "CR", Name: "Costa Rica", Rail: "global", Currency: "crc", Capability: "local"},
	{Code: "HR", Name: "Croatia", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "CY", Name: "Cyprus", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "CZ", Name: "Czech Republic", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "CI", Name: "Côte d’Ivoire", Rail: "global", Currency: "xof", Capability: "local"},
	{Code: "DK", Name: "Denmark", Rail: "connect", Currency: "dkk", Capability: "local"},
	{Code: "DO", Name: "Dominican Republic", Rail: "global", Currency: "dop", Capability: "local"},
	{Code: "EC", Name: "Ecuador", Rail: "global", Currency: "usd", Capability: "wire"},
	{Code: "EG", Name: "Egypt", Rail: "global", Currency: "egp", Capability: "wire"},
	{Code: "SV", Name: "El Salvador", Rail: "global", Currency: "usd", Capability: "wire"},
	{Code: "EE", Name: "Estonia", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "ET", Name: "Ethiopia", Rail: "global", Currency: "etb", Capability: "wire"},
	{Code: "FI", Name: "Finland", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "FR", Name: "France", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "GM", Name: "Gambia", Rail: "global", Currency: "gmd", Capability: "wire"},
	{Code: "DE", Name: "Germany", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "GR", Name: "Greece", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "GT", Name: "Guatemala", Rail: "global", Currency: "gtq", Capability: "wire"},
	{Code: "GY", Name: "Guyana", Rail: "global", Currency: "gyd", Capability: "wire"},
	{Code: "HK", Name: "Hong Kong", Rail: "global", Currency: "hkd", Capability: "wire"},
	{Code: "HU", Name: "Hungary", Rail: "connect", Currency: "huf", Capability: "local"},
	{Code: "IS", Name: "Iceland", Rail: "global", Currency: "eur", Capability: "local"},
	{Code: "IN", Name: "India", Rail: "global", Currency: "inr", Capability: "local"},
	{Code: "ID", Name: "Indonesia", Rail: "global", Currency: "idr", Capability: "local"},
	{Code: "IE", Name: "Ireland", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "IL", Name: "Israel", Rail: "global", Currency: "ils", Capability: "local"},
	{Code: "IT", Name: "Italy", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "JM", Name: "Jamaica", Rail: "global", Currency: "jmd", Capability: "local"},
	{Code: "JP", Name: "Japan", Rail: "global", Currency: "jpy", Capability: "wire"},
	{Code: "JO", Name: "Jordan", Rail: "global", Currency: "jod", Capability: "wire"},
	{Code: "KE", Name: "Kenya", Rail: "global", Currency: "kes", Capability: "wire"},
	{Code: "KW", Name: "Kuwait", Rail: "global", Currency: "kwd", Capability: "wire"},
	{Code: "LV", Name: "Latvia", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "LI", Name: "Liechtenstein", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "LT", Name: "Lithuania", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "LU", Name: "Luxembourg", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "MG", Name: "Madagascar", Rail: "global", Currency: "mga", Capability: "wire"},
	{Code: "MY", Name: "Malaysia", Rail: "global", Currency: "myr", Capability: "wire"},
	{Code: "MT", Name: "Malta", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "MU", Name: "Mauritius", Rail: "global", Currency: "mur", Capability: "wire"},
	{Code: "MX", Name: "Mexico", Rail: "global", Currency: "mxn", Capability: "local"},
	{Code: "MD", Name: "Moldova", Rail: "global", Currency: "mdl", Capability: "wire"},
	{Code: "MC", Name: "Monaco", Rail: "global", Currency: "eur", Capability: "local"},
	{Code: "MN", Name: "Mongolia", Rail: "global", Currency: "mnt", Capability: "wire"},
	{Code: "MA", Name: "Morocco", Rail: "global", Currency: "mad", Capability: "local"},
	{Code: "MZ", Name: "Mozambique", Rail: "global", Currency: "mzn", Capability: "wire"},
	{Code: "NA", Name: "Namibia", Rail: "global", Currency: "nad", Capability: "wire"},
	{Code: "NL", Name: "Netherlands", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "NZ", Name: "New Zealand", Rail: "global", Currency: "nzd", Capability: "local"},
	{Code: "MK", Name: "North Macedonia", Rail: "global", Currency: "mkd", Capability: "wire"},
	{Code: "NO", Name: "Norway", Rail: "connect", Currency: "nok", Capability: "local"},
	{Code: "OM", Name: "Oman", Rail: "global", Currency: "omr", Capability: "wire"},
	{Code: "PK", Name: "Pakistan", Rail: "global", Currency: "pkr", Capability: "wire"},
	{Code: "PA", Name: "Panama", Rail: "global", Currency: "usd", Capability: "wire"},
	{Code: "PE", Name: "Peru", Rail: "global", Currency: "pen", Capability: "local"},
	{Code: "PH", Name: "Philippines", Rail: "global", Currency: "php", Capability: "wire"},
	{Code: "PL", Name: "Poland", Rail: "connect", Currency: "pln", Capability: "local"},
	{Code: "PT", Name: "Portugal", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "QA", Name: "Qatar", Rail: "global", Currency: "qar", Capability: "wire"},
	{Code: "RO", Name: "Romania", Rail: "connect", Currency: "ron", Capability: "local"},
	{Code: "RW", Name: "Rwanda", Rail: "global", Currency: "rwf", Capability: "wire"},
	{Code: "SM", Name: "San Marino", Rail: "global", Currency: "eur", Capability: "local"},
	{Code: "SN", Name: "Senegal", Rail: "global", Currency: "xof", Capability: "local"},
	{Code: "RS", Name: "Serbia", Rail: "global", Currency: "rsd", Capability: "wire"},
	{Code: "SG", Name: "Singapore", Rail: "global", Currency: "sgd", Capability: "local"},
	{Code: "SK", Name: "Slovakia", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "SI", Name: "Slovenia", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "ZA", Name: "South Africa", Rail: "global", Currency: "zar", Capability: "wire"},
	{Code: "ES", Name: "Spain", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "LK", Name: "Sri Lanka", Rail: "global", Currency: "lkr", Capability: "wire"},
	{Code: "LC", Name: "Saint Lucia", Rail: "global", Currency: "xcd", Capability: "wire"},
	{Code: "SE", Name: "Sweden", Rail: "connect", Currency: "sek", Capability: "local"},
	{Code: "CH", Name: "Switzerland", Rail: "connect", Currency: "eur", Capability: "local"},
	{Code: "TW", Name: "Taiwan", Rail: "global", Currency: "twd", Capability: "wire"},
	{Code: "TZ", Name: "Tanzania", Rail: "global", Currency: "tzs", Capability: "wire"},
	{Code: "TH", Name: "Thailand", Rail: "global", Currency: "thb", Capability: "wire"},
	{Code: "TT", Name: "Trinidad and Tobago", Rail: "global", Currency: "ttd", Capability: "local"},
	{Code: "TN", Name: "Tunisia", Rail: "global", Currency: "tnd", Capability: "local"},
	{Code: "TR", Name: "Turkey", Rail: "global", Currency: "try", Capability: "wire"},
	{Code: "AE", Name: "United Arab Emirates", Rail: "global", Currency: "aed", Capability: "wire"},
	{Code: "GB", Name: "United Kingdom", Rail: "connect", Currency: "gbp", Capability: "local"},
	{Code: "US", Name: "United States", Rail: "connect", Currency: "usd", Capability: "wire"},
	{Code: "UZ", Name: "Uzbekistan", Rail: "global", Currency: "uzs", Capability: "wire"},
	{Code: "VN", Name: "Vietnam", Rail: "global", Currency: "vnd", Capability: "wire"},
}

func Lookup(code string) (Country, bool) {
	for _, c := range Countries {
		if c.Code == code {
			return c, true
		}
	}
	return Country{}, false
}
