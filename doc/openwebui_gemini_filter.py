"""
title: Gemini Native Image Gen & Edit Pipe
author: OpenWebUI User
description: Calls Google's Gemini API for native image generation and interactive
    editing. On the first turn with text only, generates an image from the text prompt.
    If the first turn includes both text and an image attachment, the image and text are
    sent together for image editing. On subsequent turns, sends the latest image (from
    the most recent model response or user upload) together with the new user instruction,
    mimicking the Gemini web app's editing workflow.
version: 2.0.0
"""

import os
import re
import json
import requests
from pydantic import BaseModel, Field
from typing import Generator, Union


class Pipe:
    class Valves(BaseModel):
        GOOGLE_API_KEY: str = Field(
            default="",
            description="Your Google AI Studio API Key",
        )
        SAFETY_THRESHOLD: str = Field(
            default="BLOCK_NONE",
            description="Threshold: BLOCK_NONE, BLOCK_ONLY_HIGH, BLOCK_MEDIUM_AND_ABOVE, BLOCK_LOW_AND_ABOVE",
        )

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        return [
            {
                "id": "gemini-3.1-flash-image",
                "name": "Gemini 3.1 Flash Image (Permissive)",
            },
            {
                "id": "gemini-3-pro-image-preview",
                "name": "Gemini 3 Pro Image (Permissive)",
            },
        ]

    def _extract_images_from_content(self, content) -> list:
        """Extract all images from a message content field.

        Returns a list of dicts: {"mimeType": ..., "data": ...}
        Handles both the OpenAI-style list format (user messages with image_url)
        and markdown-embedded base64 format (assistant responses).
        """
        images = []

        if isinstance(content, list):
            # OpenAI-compatible format: [{type: "image_url", image_url: {url: "data:..."}}]
            for item in content:
                if isinstance(item, dict) and item.get("type") == "image_url":
                    img_url = item.get("image_url", {}).get("url", "")
                    if img_url.startswith("data:"):
                        match = re.match(
                            r"data:(image/[^;]+);base64,(.*)", img_url, re.DOTALL
                        )
                        if match:
                            images.append(
                                {
                                    "mimeType": match.group(1),
                                    "data": re.sub(r"\s+", "", match.group(2)),
                                }
                            )

        elif isinstance(content, str):
            # Markdown-embedded base64: ![...](data:image/...;base64,...)
            pattern = r"!\[.*?\]\(data:(image/[a-zA-Z0-9\+\-\.]+);base64,([A-Za-z0-9+/=\s]+)\)"
            for match in re.finditer(pattern, content):
                images.append(
                    {
                        "mimeType": match.group(1),
                        "data": re.sub(r"\s+", "", match.group(2)),
                    }
                )

        return images

    def _extract_text_from_content(self, content) -> str:
        """Extract the text portion from a message content field.

        Handles both list format and string format. For strings, strips out
        any markdown image embeds to return only the textual instruction.
        """
        if isinstance(content, list):
            texts = []
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    text_val = item.get("text", "").strip()
                    if text_val:
                        texts.append(text_val)
            return " ".join(texts)

        elif isinstance(content, str):
            # Remove markdown image embeds to isolate the text instruction
            cleaned = re.sub(
                r"!\[.*?\]\(data:image/[^)]+\)",
                "",
                content,
            )
            return cleaned.strip()

        return ""

    def _find_latest_image(self, messages: list) -> dict | None:
        """Walk messages in reverse to find the most recent image.

        Checks assistant (model) responses first (the editing result),
        then user messages (an uploaded image). Returns the first image
        found as {"mimeType": ..., "data": ...}, or None.
        """
        for msg in reversed(messages):
            images = self._extract_images_from_content(msg.get("content", ""))
            if images:
                # Return the last image in that message (the final generated/uploaded one)
                return images[-1]
        return None

    def pipe(self, body: dict, __user__: dict = None) -> Union[str, Generator]:
        api_key = self.valves.GOOGLE_API_KEY or os.getenv("GEMINI_API_KEY", "")
        if not api_key:
            return "Error: Google API Key is not configured in Valves."

        raw_model = body.get("model", "gemini-3.1-flash-image")
        model_id = raw_model.split("/")[-1]
        if "." in model_id and not model_id.startswith("gemini-"):
            model_id = model_id.split(".", 1)[-1]

        threshold = self.valves.SAFETY_THRESHOLD
        messages = body.get("messages", [])

        if not messages:
            return "Error: No messages in the request."

        # --- Build the Gemini request contents ---
        # Strategy: mimic the Gemini web app for interactive editing.
        #
        # Turn 1 (text only, no prior images):
        #   Send a single user turn with just the text prompt.
        #
        # Turn 1 (text + image attachment):
        #   Send a single user turn with the attached image and text as
        #   an editing instruction: [image, text].
        #
        # Turn N (editing session):
        #   Find the latest image from the conversation (most recent model
        #   response or user upload) and pair it with the latest user text
        #   as a single user turn: [image, text].
        #
        # This avoids sending the full conversation history (which would
        # re-send every intermediate base64 image, bloating the payload
        # and burning tokens). Each editing turn is self-contained.

        # Get the latest user message text
        latest_user_msg = messages[-1]
        user_text = self._extract_text_from_content(latest_user_msg.get("content", ""))

        # Check if the latest user message itself has an image
        latest_user_images = self._extract_images_from_content(
            latest_user_msg.get("content", "")
        )

        # Look for the latest image across the whole conversation history
        # (excluding the current user message, we already checked it)
        history_messages = messages[:-1]  # all except the latest user message
        latest_history_image = self._find_latest_image(history_messages)

        # Decide which image to use: prefer the user's new upload, fall back
        # to the most recent image from history (typically the model's last output)
        latest_image = (
            latest_user_images[-1] if latest_user_images else latest_history_image
        )

        # Build the parts for a single user turn
        parts = []

        if latest_image:
            # Include the image as inlineData
            parts.append(
                {
                    "inlineData": {
                        "mimeType": latest_image["mimeType"],
                        "data": latest_image["data"],
                    }
                }
            )

        if user_text:
            parts.append({"text": user_text})

        if not parts:
            return "Error: Could not extract any content from the conversation."

        contents = [{"role": "user", "parts": parts}]

        payload = {
            "contents": contents,
            "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
            "safetySettings": [
                {"category": "HARM_CATEGORY_HARASSMENT", "threshold": threshold},
                {"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": threshold},
                {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": threshold},
                {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": threshold},
                {"category": "HARM_CATEGORY_CIVIC_INTEGRITY", "threshold": threshold},
            ],
        }

        url = (
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{model_id}:generateContent?key={api_key}"
        )

        try:
            response = requests.post(
                url,
                headers={"Content-Type": "application/json"},
                json=payload,
                timeout=300,
            )
        except requests.exceptions.Timeout:
            return "Error: Request to Gemini API timed out (300s)."
        except requests.exceptions.RequestException as e:
            return f"Error: Network error communicating with Gemini API: {e}"

        if response.status_code != 200:
            return f"Error {response.status_code}: {response.text}"

        res_json = response.json()
        try:
            candidate_parts = res_json["candidates"][0]["content"]["parts"]
            output_elements = []

            for part in candidate_parts:
                if "text" in part:
                    output_elements.append(part["text"])
                elif "inlineData" in part:
                    mime_type = part["inlineData"].get("mimeType", "image/jpeg")
                    b64_data = part["inlineData"].get("data", "")
                    output_elements.append(
                        f"\n\n![Generated Image](data:{mime_type};base64,{b64_data})\n\n"
                    )

            if output_elements:
                return "".join(output_elements).strip()
            return "No content returned by the model."

        except (KeyError, IndexError):
            return f"```json\n{json.dumps(res_json, indent=2)}\n```"
