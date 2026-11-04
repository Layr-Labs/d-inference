### A pair no longer drops all its requests when one request runs out of time before it starts

- Only that request now fails, with a deadline error, and the pair keeps serving.
