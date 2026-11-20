### A pair asks for its approval again once the other Mac is back

- A pair that wasn't offered to Darkbloom yet (for example after a failed approval save) asked the coordinator for its cluster approval only once per run of its cluster service. When that one check came while the other Mac didn't answer, or while another cluster command was running, it changed nothing and nothing asked again: the pair kept serving only on its local API after the other Mac came back, until the service restarted. Such a check is now tried again a minute later, so the pair is offered once both Macs answer.
