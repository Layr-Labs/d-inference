### The provider zeroes the response text it gathers

- The provider now keeps the response text it gathers while streaming (for the response hash, the billing floor and the reasoning token count) in storage that is zeroed as it grows and when the request ends. The response hash is unchanged and is computed without another copy of the text.
