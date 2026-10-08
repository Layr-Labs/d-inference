"""Live organization membership for the member-only automatic merge path."""
import re

from .client import APIError, ReviewUnavailable, request_json

ORGANIZATION = "Layr-Labs"
ORGANIZATION_ID = 92827658


def active_member(author, token, transport=request_json):
    """Require a current active human membership, never PR association or access.

    The dedicated token needs organization Members: read. Missing permission,
    private membership lookup failures and malformed responses cannot clear a PR.
    """
    if not token or not isinstance(author, dict) or author.get("type") != "User":
        return False
    login = author.get("login")
    identity = author.get("id")
    if (not isinstance(login, str) or not re.fullmatch(r"[A-Za-z0-9-]+", login)
            or type(identity) is not int or identity <= 0):
        return False
    try:
        membership = transport(f"https://api.github.com/orgs/{ORGANIZATION}/memberships/{login}", token)
    except APIError as error:
        if error.status == 404:
            return False
        raise ReviewUnavailable("Organization membership could not be verified; independent human review required") from None
    if not isinstance(membership, dict):
        return False
    organization, user = membership.get("organization"), membership.get("user")
    return (membership.get("state") == "active" and membership.get("role") in ("member", "admin")
            and isinstance(organization, dict) and type(organization.get("id")) is int
            and organization["id"] == ORGANIZATION_ID
            and isinstance(user, dict) and type(user.get("id")) is int and user["id"] == identity
            and user.get("type") == "User" and isinstance(user.get("login"), str)
            and user["login"].lower() == login.lower())
