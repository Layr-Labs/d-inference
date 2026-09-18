package trial

const (
	ExhaustedCode       = "bonsai_trial_exhausted"
	BusyCode            = "bonsai_trial_busy"
	RequestTooLargeCode = "bonsai_trial_request_too_large"
	UnavailableCode     = "bonsai_trial_unavailable"

	ExhaustedMessage       = "Hey, you've used all 5 million free tokens for Bonsai 2. You can continue with a funded API key in the API Console."
	BusyMessage            = "Your free Bonsai 2 allowance is currently reserved by another request. Wait for it to finish, then try again."
	RequestTooLargeMessage = "This request exceeds your remaining free Bonsai 2 allowance. Try a shorter conversation or a smaller response."
	UnavailableMessage     = "Free Bonsai 2 chat is temporarily unavailable. Please try again later."
)
