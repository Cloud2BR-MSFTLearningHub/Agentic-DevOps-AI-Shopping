from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Sequence

from azure.core.credentials import AccessToken, TokenCredential
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential


COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"
AI_FOUNDRY_SCOPE = "https://ai.azure.com/.default"


@dataclass(frozen=True)
class FixedScopeTokenCredential(TokenCredential):
    """Wraps a TokenCredential and forces a fixed scope.

    Some Azure SDK clients derive the scope from the endpoint and can request an
    unexpected audience for Azure AI Foundry model inference endpoints.

    Azure AI (Cognitive Services) expects tokens for:
      https://cognitiveservices.azure.com/.default

    This wrapper ensures we always request the correct audience.
    """

    inner: TokenCredential
    scope: str = COGNITIVE_SERVICES_SCOPE

    def get_token(self, *scopes: str, **kwargs) -> AccessToken:  # type: ignore[override]
        return self.inner.get_token(self.scope, **kwargs)


def get_inference_credential(
  api_key: str | None,
  default_credential: TokenCredential,
  endpoint: str | None = None,
) -> TokenCredential:
    """Return a credential appropriate for Azure AI Inference.

    - If an API key is present, callers should still use AzureKeyCredential.
      (This helper only returns TokenCredential for MI/AAD flows.)
    - For MI/AAD flows, return a TokenCredential that always requests the
      Cognitive Services audience.
    """

    # api_key is ignored here; we only wrap token credentials.
    scope = COGNITIVE_SERVICES_SCOPE
    if endpoint and "services.ai.azure.com" in endpoint:
      scope = AI_FOUNDRY_SCOPE
    return FixedScopeTokenCredential(default_credential, scope=scope)


def get_default_credential() -> TokenCredential:
    """Return a TokenCredential that prefers managed identity in Azure.

    Falls back to DefaultAzureCredential if managed identity is unavailable
    (e.g., local runs during terraform apply).
    """

    client_id = os.getenv("AZURE_CLIENT_ID") or os.getenv("MANAGED_IDENTITY_CLIENT_ID")
    if client_id:
        mi = ManagedIdentityCredential(client_id=client_id)
        try:
            # Validate MI availability to avoid local failures.
            mi.get_token(COGNITIVE_SERVICES_SCOPE)
            return mi
        except Exception:
            return DefaultAzureCredential()
    return DefaultAzureCredential()
