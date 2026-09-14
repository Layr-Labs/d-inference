// Package schema owns the ordered startup DDL. Backend code owns execution,
// transactions and the separately gated data migrations.
package schema

// Statements returns a fresh list in the established migration order. Keep this
// order when editing a domain: the ordinal identifies failures in startup logs,
// and legacy compatibility statements can precede a later table creation.
func Statements(rewardTypesSQL string) []string {
	var statements []string
	statements = append(statements, bootstrap()...)
	statements = append(statements, providerRecords()...)
	statements = append(statements, apiKeys()...)
	statements = append(statements, usage()...)
	statements = append(statements, ledger(rewardTypesSQL)...)
	statements = append(statements, billing()...)
	statements = append(statements, modelRegistry()...)
	statements = append(statements, releases()...)
	statements = append(statements, deviceAuth()...)
	statements = append(statements, providerEarnings()...)
	statements = append(statements, withdrawals()...)
	statements = append(statements, usageCounters()...)
	statements = append(statements, providerOperations()...)
	statements = append(statements, routes()...)
	statements = append(statements, rejections()...)
	statements = append(statements, codeAttestation()...)
	statements = append(statements, trustReuse()...)
	statements = append(statements, verification()...)
	statements = append(statements, providerRewards()...)
	statements = append(statements, profiles()...)
	return statements
}
