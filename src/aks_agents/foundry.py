from __future__ import annotations

from typing import Protocol, TypeVar

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from opentelemetry import trace
from openai import AsyncAzureOpenAI
from pydantic import BaseModel, ValidationError

from .settings import Settings

ResponseModel = TypeVar("ResponseModel", bound=BaseModel)
tracer = trace.get_tracer(__name__)


class StructuredChatClient(Protocol):
    async def complete_structured(
        self,
        system: str,
        user: str,
        response_model: type[ResponseModel],
    ) -> ResponseModel: ...


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
        self._max_output_tokens = settings.foundry_max_output_tokens
        self._validation_retries = settings.foundry_validation_retries
        self.client = AsyncAzureOpenAI(
            azure_endpoint=str(settings.foundry_endpoint),
            api_version=settings.foundry_api_version,
            azure_ad_token_provider=token_provider,
            timeout=settings.foundry_timeout_seconds,
            max_retries=2,
        )

    async def complete_structured(
        self,
        system: str,
        user: str,
        response_model: type[ResponseModel],
    ) -> ResponseModel:
        schema_name = response_model.__name__.strip("_").casefold()
        last_error: ValidationError | None = None
        with tracer.start_as_current_span("foundry.complete") as span:
            span.set_attribute("gen_ai.system", "azure_openai")
            span.set_attribute("gen_ai.request.model", self.model)
            span.set_attribute("agent.response_schema", response_model.__name__)
            for attempt in range(self._validation_retries + 1):
                response = await self.client.chat.completions.create(
                    model=self.model,
                    messages=[
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                    max_completion_tokens=self._max_output_tokens,
                    response_format={
                        "type": "json_schema",
                        "json_schema": {
                            "name": schema_name,
                            "strict": True,
                            "schema": response_model.model_json_schema(),
                        },
                    },
                )
                content = response.choices[0].message.content
                if not content:
                    raise RuntimeError("Foundry returned no structured content")
                try:
                    result = response_model.model_validate_json(content)
                    span.set_attribute("agent.validation_attempts", attempt + 1)
                    return result
                except ValidationError as exc:
                    last_error = exc
            span.set_attribute("agent.validation_failed", True)
        raise RuntimeError("Foundry returned invalid structured output") from last_error
