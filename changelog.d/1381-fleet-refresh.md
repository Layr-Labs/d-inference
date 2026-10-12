### Fleet loading resilience

- Keep the provider dashboard loading and refreshing machines when the optional earnings summary stalls, including while its response body is incomplete. Pending summary requests remain bounded to one per account session and are cancelled on account change or unmount.
