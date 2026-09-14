enum GuestDomainTestFixture {
    static let observed = """
user/2001 = {
\ttype = user
\thandle = 2001
\tactive count = 2
\tcreator = launchctl[516]
\tcreator euid = 0
\tsession = Background
\texternal activation count = 1
\tsecurity context = {
\t\tuid = 2001
\t\tasid = 100028
\t}

\tdeath port = 0x0
\tin-progress bootstraps = 1

\tservices = {
\t}

\tunmanaged processes = {
\t}

\tendpoints = {
\t}

\ttask-special ports = {
\t\t\t 0x82503 4       bootstrap  com.apple.xpc.launchd.domain.user.2001
\t\t\t  0x2b03 9          access  (unknown)
\t}


\tproperties = shutting down | slain
}

"""
}
