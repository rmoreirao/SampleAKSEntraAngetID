from __future__ import annotations

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncAzureOpenAI

from .settings import Settings


class FoundryChatClient:
    def __init__(self, settings: Settings) -> None:
        if not settings.foundry_enabled:
            raise RuntimeError("Foundry client is disabled")
        if not settings.foundry_endpoint or not settings.foundry_model:
            raise RuntimeError(
                "Foundry requires APP_FOUNDRY_ENDPOINT and APP_FOUNDRY_MODEL"
            )
        credential = DefaultAzureCredential(managed_identity_client_id=settings.uami_client_id)
        token_provider = get_bearer_token_provider(
            credential, "https://cognitiveservices.azure.com/.default"
        )
        self.model = settings.foundry_model
        self.client = AsyncAzureOpenAI(
            azure_endpoint=str(settings.foundry_endpoint),
            api_version=settings.foundry_api_version,
            azure_ad_token_provider=token_provider,
        )

    async def complete(self, system: str, user: str) -> str:
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        return response.choices[0].message.content or ""
