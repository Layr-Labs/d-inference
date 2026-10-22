SSH = ['/usr/bin/ssh', '-T', '-S', 'none', '-o', 'BatchMode=yes',
       '-o', 'ConnectTimeout=5', '-o', 'IdentitiesOnly=yes',
       '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o',
       'UserKnownHostsFile=/Users/developer/DarkbloomDev/cluster-research/owner-ssh-preflight-20260915/known_hosts',
       '-i', '/Users/developer/.ssh/id_ed25519_darkbloom_dev']
