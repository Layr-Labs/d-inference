### Console desktop sign-in approval

- Approve Darkbloom Desktop sign-in codes on `console.darkbloom.dev/link?purpose=desktop_account`: the link page now sends the code's purpose (`desktop_account` or `provider`) with the approval, so desktop sign-in no longer fails with "authorization purpose does not match this code". Provider linking is unchanged. This ports the link page from darkbloom-platform#23 into the console that still serves `console.darkbloom.dev`.
