"""Cloud clients use ADC, or an explicitly supplied short-lived pilot token."""

import os

from google.cloud import bigquery, storage
from google.oauth2.credentials import Credentials


def credentials():
    token = os.environ.get("ARCHIVE_GOOGLE_ACCESS_TOKEN")
    return Credentials(token) if token else None


def storage_client(project: str):
    return storage.Client(project=project, credentials=credentials())


def bigquery_client(project: str, location: str):
    return bigquery.Client(project=project, location=location, credentials=credentials())
