import hashlib
import os
import re
import time
from typing import Optional

import numpy as np
import requests
import wikipedia
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from google import genai
from google.genai import types
from pydantic import BaseModel
from supabase import Client, create_client

load_dotenv()

REQUIRED_VARS = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "GEMINI_API_KEY"]
missing_vars = [v for v in REQUIRED_VARS if not os.environ.get(v)]
if missing_vars:
    raise RuntimeError(f"Missing required environment variables: {', '.join(missing_vars)}")

app = FastAPI(title="ChronoScape 3D Backend", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ==========================================
# CLIENTS & CONSTANTS
# ==========================================
WIKI_URL = "https://commons.wikimedia.org/w/api.php"
EUROPEANA_URL = "https://api.europeana.eu/record/v2/search.json"
WIKI_HEADERS = {
    "User-Agent": "ChronoScape3D/1.0 (https://github.com/reyanmuzamil/mobile-app-project; reyanmuzamil4@gmail.com)"
}
ART_KEYWORDS = (
    "painting", "engraving", "lithograph", "watercolor", "watercolour",
    "sketch", "drawing", "etching", "18th century", "19th century", "print"
)
HISTORICAL_ALIASES = {
    "Badshahi Mosque": ["Badshahi Masjid", "Badshahi Mosque", "Mosque Lahore"],
    "Lahore Fort": ["Lahore Fort", "Fort of Lahore", "Citadel Lahore"],
    "Baltit Fort": ["Baltit Fort", "Baltit Hunza", "Hunza Fort"],
    "Altit Fort": ["Altit Fort", "Altit Hunza"],
    "Shigar Fort": ["Shigar Fort", "Shigar Baltistan"],
    "Rohtas Fort": ["Rohtas Fort", "Rhotas Fort"],
    "Derawar Fort": ["Derawar Fort", "Dirawar Fort"],
}

wikipedia.set_user_agent(
    "ChronoScape3D/1.0 (https://github.com/reyanmuzamil/mobile-app-project; reyanmuzamil4@gmail.com)"
)

supabase_client: Client = create_client(
    os.environ["SUPABASE_URL"],
    os.environ["SUPABASE_SERVICE_ROLE_KEY"],
)
genai_client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])


# ==========================================
# REQUEST MODELS
# ==========================================
class ExploreRequest(BaseModel):
    name: str
    lat: float
    lon: float
    wikidata_id: Optional[str] = None


class AskRequest(BaseModel):
    landmark_name: str
    lat: float
    lon: float
    question: str
    era_filter: Optional[int] = None


# ==========================================
# HELPERS & BATCH EMBEDDINGS
# ==========================================
def clean_html(raw_html: str) -> str:
    if not raw_html:
        return ""
    return re.sub(r"<.*?>", "", raw_html).strip()


def extract_year(raw_date: str) -> Optional[int]:
    if not raw_date:
        return None
    match = re.search(r"\b(1[4-9]\d{2}|20\d{2})\b", str(raw_date))
    return int(match.group(1)) if match else None


def first_item(val, default=""):
    if isinstance(val, list) and len(val) > 0:
        return val[0]
    return val if val else default


def get_embeddings_batch(texts: list[str]) -> list[list[float]]:
    if not texts:
        return []
    for attempt in range(3):
        try:
            response = genai_client.models.embed_content(
                model="gemini-embedding-001",
                contents=texts,
                config=types.EmbedContentConfig(output_dimensionality=768),
            )
            vectors = []
            for emb in response.embeddings:
                vec = np.array(emb.values, dtype=np.float32)
                norm = np.linalg.norm(vec)
                if norm > 0:
                    vec = vec / norm
                vectors.append(vec.tolist())
            return vectors
        except Exception as e:
            if "429" in str(e) and attempt < 2:
                time.sleep(65)
            else:
                raise e


# ==========================================
# ARCHIVAL MEDIA FETCHERS (PRE-1900 + MODERN)
# ==========================================
def fetch_pre1900_paintings(landmark_name: str, limit: int = 10) -> list[dict]:
    results = []
    seen_ids = set()
    search_names = HISTORICAL_ALIASES.get(landmark_name, [landmark_name])

    art_terms = ["painting", "engraving", "lithograph", "19th century", "watercolor"]
    for alias in search_names:
        for term in art_terms:
            if len(results) >= limit:
                break
            wiki_params = {
                "action": "query",
                "generator": "search",
                "gsrsearch": f"{alias} {term}",
                "gsrnamespace": 6,
                "gsrlimit": 5,
                "prop": "imageinfo",
                "iiprop": "url|extmetadata",
                "iiurlwidth": 800,
                "format": "json",
            }
            try:
                r = requests.get(WIKI_URL, params=wiki_params, headers=WIKI_HEADERS, timeout=12).json()
                for page_id, page in r.get("query", {}).get("pages", {}).items():
                    if str(page_id) in seen_ids:
                        continue
                    info_list = page.get("imageinfo", [])
                    if not info_list:
                        continue
                    info = info_list[0]
                    clean_url = info.get("url", "").split("?")[0]
                    if not clean_url.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
                        continue

                    ext = info.get("extmetadata", {})
                    raw_title = ext.get("ObjectName", {}).get("value") or page.get("title", "").replace("File:", "")
                    raw_desc = ext.get("ImageDescription", {}).get("value", "")
                    raw_date = ext.get("DateTimeOriginal", {}).get("value", "")
                    raw_artist = ext.get("Artist", {}).get("value", "Historical Artist")
                    license_name = ext.get("LicenseShortName", {}).get("value", "Public Domain")

                    title_clean = clean_html(raw_title)[:200]
                    desc_clean = clean_html(raw_desc)[:500]
                    year = extract_year(raw_date) or extract_year(title_clean) or extract_year(desc_clean)

                    combined_lower = f"{title_clean} {desc_clean}".lower()
                    is_art = any(kw in combined_lower for kw in ART_KEYWORDS)
                    if year and year > 1920 and not is_art:
                        continue

                    seen_ids.add(str(page_id))
                    results.append({
                        "source": "wikimedia",
                        "source_id": f"art_{page_id}",
                        "title": title_clean,
                        "description": desc_clean,
                        "media_type": "painting",
                        "year_start": year,
                        "year_end": year,
                        "image_url": clean_url,
                        "thumb_url": info.get("thumburl", clean_url).split("?")[0],
                        "license": license_name,
                        "attribution": clean_html(raw_artist)[:150],
                        "source_url": info.get("descriptionurl", ""),
                        "badge": "Pre-1900 Artwork",
                        "confidence": 0.92,
                    })
            except Exception:
                pass

    api_key = os.environ.get("EUROPEANA_API_KEY")
    if api_key:
        for alias in search_names:
            if len(results) >= limit:
                break
            try:
                resp = requests.get(
                    EUROPEANA_URL,
                    params={
                        "wskey": api_key,
                        "query": f'"{alias}"',
                        "qf": "TYPE:IMAGE",
                        "media": "true",
                        "rows": limit,
                    },
                    timeout=12,
                ).json()
                for item in resp.get("items", []):
                    item_id = item.get("id", "")
                    if item_id in seen_ids:
                        continue
                    full_url = first_item(item.get("edmIsShownBy"), "")
                    preview_url = first_item(item.get("edmPreview"), "")
                    image_url = full_url if full_url.lower().endswith((".jpg", ".jpeg", ".png", ".webp")) else preview_url
                    if not image_url:
                        continue

                    provider = first_item(item.get("dataProvider"), "Europeana Archive")
                    raw_year = first_item(item.get("year"), "")
                    year = extract_year(str(raw_year))

                    seen_ids.add(item_id)
                    results.append({
                        "source": "europeana",
                        "source_id": item_id,
                        "title": str(first_item(item.get("title"), landmark_name))[:200],
                        "description": str(first_item(item.get("dcDescription"), ""))[:500],
                        "media_type": "painting",
                        "year_start": year,
                        "year_end": year,
                        "image_url": image_url,
                        "thumb_url": preview_url or image_url,
                        "license": str(first_item(item.get("rights"), "Public Domain")),
                        "attribution": str(provider)[:150],
                        "source_url": item.get("guid", ""),
                        "badge": "British Library" if "british library" in provider.lower() else "Pre-1900 Archive",
                        "confidence": 0.96,
                    })
            except Exception:
                pass

    return results[:limit]


def fetch_wikimedia_clean(landmark_name: str, lat: float, lon: float, limit: int = 12) -> list[dict]:
    results = []
    seen_ids = set()

    def _parse(pages_dict: dict):
        for page_id, page in pages_dict.items():
            if str(page_id) in seen_ids:
                continue
            info_list = page.get("imageinfo", [])
            if not info_list:
                continue
            info = info_list[0]
            clean_url = info.get("url", "").split("?")[0]
            if not clean_url.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
                continue

            clean_thumb = info.get("thumburl", clean_url).split("?")[0]
            ext = info.get("extmetadata", {})
            raw_title = ext.get("ObjectName", {}).get("value") or page.get("title", "").replace("File:", "")
            raw_desc = ext.get("ImageDescription", {}).get("value", "")
            raw_date = ext.get("DateTimeOriginal", {}).get("value", "")
            raw_artist = ext.get("Artist", {}).get("value", "Wikimedia Contributor")
            license_name = ext.get("LicenseShortName", {}).get("value", "Unknown")
            year = extract_year(raw_date)

            seen_ids.add(str(page_id))
            results.append({
                "source": "wikimedia",
                "source_id": str(page_id),
                "title": clean_html(raw_title)[:200],
                "description": clean_html(raw_desc)[:500],
                "media_type": "image",
                "year_start": year,
                "year_end": year,
                "image_url": clean_url,
                "thumb_url": clean_thumb,
                "license": license_name,
                "attribution": clean_html(raw_artist)[:150],
                "source_url": info.get("descriptionurl", ""),
                "badge": "Archival" if (year and year < 1970) else "Community",
                "confidence": 0.85,
            })

    try:
        geo_params = {
            "action": "query",
            "generator": "geosearch",
            "ggscoord": f"{lat}|{lon}",
            "ggsradius": 1000,
            "ggsnamespace": 6,
            "ggslimit": limit,
            "prop": "imageinfo",
            "iiprop": "url|extmetadata",
            "iiurlwidth": 800,
            "format": "json",
        }
        r1 = requests.get(WIKI_URL, params=geo_params, headers=WIKI_HEADERS, timeout=12).json()
        _parse(r1.get("query", {}).get("pages", {}))
    except Exception:
        pass

    if len(results) < limit:
        try:
            search_params = {
                "action": "query",
                "generator": "search",
                "gsrsearch": landmark_name,
                "gsrnamespace": 6,
                "gsrlimit": limit,
                "prop": "imageinfo",
                "iiprop": "url|extmetadata",
                "iiurlwidth": 800,
                "format": "json",
            }
            r2 = requests.get(WIKI_URL, params=search_params, headers=WIKI_HEADERS, timeout=12).json()
            _parse(r2.get("query", {}).get("pages", {}))
        except Exception:
            pass

    return results[:limit]


def fetch_europeana_images(landmark_name: str, rows: int = 12) -> list[dict]:
    api_key = os.environ.get("EUROPEANA_API_KEY")
    if not api_key:
        return []
    try:
        resp = requests.get(
            EUROPEANA_URL,
            params={
                "wskey": api_key,
                "query": f'"{landmark_name}"',
                "qf": "TYPE:IMAGE",
                "media": "true",
                "rows": rows,
            },
            timeout=12,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception:
        return []

    results = []
    for item in data.get("items", []):
        full_url = first_item(item.get("edmIsShownBy"), "")
        preview_url = first_item(item.get("edmPreview"), "")
        image_url = full_url if full_url.lower().endswith((".jpg", ".jpeg", ".png", ".webp")) else preview_url
        thumb_url = preview_url or image_url
        if not image_url:
            continue

        provider = first_item(item.get("dataProvider"), "Europeana Partner")
        badge = "British Library" if "british library" in provider.lower() else "Verified Archive"
        raw_year = first_item(item.get("year"), "")
        if not raw_year:
            timespan = first_item(item.get("edmTimespanLabel"), {})
            raw_year = timespan.get("def", "") if isinstance(timespan, dict) else ""
        year = extract_year(str(raw_year))

        results.append({
            "source": "europeana",
            "source_id": item.get("id", ""),
            "title": str(first_item(item.get("title"), landmark_name))[:200],
            "description": str(first_item(item.get("dcDescription"), ""))[:500],
            "media_type": "image",
            "year_start": year,
            "year_end": year,
            "image_url": image_url,
            "thumb_url": thumb_url,
            "license": str(first_item(item.get("rights"), "Unknown")),
            "attribution": str(provider)[:150],
            "source_url": item.get("guid", ""),
            "badge": badge,
            "confidence": 0.95,
        })
    return results


def fetch_and_chunk_wikipedia(landmark_name: str, chunk_size: int = 800, overlap: int = 150) -> tuple[str, str, list[dict]]:
    page = wikipedia.page(landmark_name, auto_suggest=True)
    summary = page.summary[:600]
    source_url = page.url
    full_text = page.content

    chunks = []
    start = 0
    while start < len(full_text):
        end = start + chunk_size
        chunk_text = full_text[start:end].strip()
        if len(chunk_text) > 100:
            chunks.append({
                "source_url": source_url,
                "text": chunk_text,
                "year_hint": extract_year(chunk_text),
            })
        start += (chunk_size - overlap)

    return summary, source_url, chunks[:20]


def get_or_ingest_landmark(name: str, lat: float, lon: float, wikidata_id: Optional[str] = None) -> dict:
    """Returns existing landmark from Supabase, or ingests it on-demand if unseeded."""
    existing = (
        supabase_client.table("landmarks")
        .select("*")
        .ilike("name", name.strip())
        .limit(1)
        .execute()
        .data
    )
    if existing:
        return existing[0]

    try:
        summary, _, chunks = fetch_and_chunk_wikipedia(name)
    except Exception as e:
        raise HTTPException(status_code=404, detail=f"Could not retrieve historical records for '{name}': {e}")

    insert_payload = {
        "name": name.strip(),
        "lat": lat,
        "lon": lon,
        "summary": summary,
    }
    if wikidata_id:
        insert_payload["wikidata_id"] = wikidata_id

    lm_res = supabase_client.table("landmarks").insert(insert_payload).execute()
    landmark = lm_res.data[0]
    landmark_id = landmark["id"]

    if chunks:
        chunk_vecs = get_embeddings_batch([c["text"] for c in chunks])
        chunk_rows = [
            {
                "landmark_id": landmark_id,
                "source_url": c["source_url"],
                "text": c["text"],
                "year_hint": c["year_hint"],
                "embedding": vec,
            }
            for c, vec in zip(chunks, chunk_vecs)
        ]
        supabase_client.table("knowledge_chunks").insert(chunk_rows).execute()

    raw_imgs = (
        fetch_pre1900_paintings(name)
        + fetch_wikimedia_clean(name, lat, lon)
        + fetch_europeana_images(name)
    )
    # Deduplicate by (source, source_id)
    seen_media = set()
    imgs = []
    for item in raw_imgs:
        key = (item["source"], item["source_id"])
        if key not in seen_media:
            seen_media.add(key)
            imgs.append(item)

    if imgs:
        media_vecs = get_embeddings_batch([f"{i['title']} - {i['description']}".strip() for i in imgs])
        for img, vec in zip(imgs, media_vecs):
            img["landmark_id"] = landmark_id
            img["embedding"] = vec
        supabase_client.table("media").insert(imgs).execute()

    return landmark


# ==========================================
# API ENDPOINTS
# ==========================================
@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/explore")
def explore_landmark(req: ExploreRequest):
    """Fetches landmark summary + pre-1900 paintings & modern photos (auto-ingests if unseeded)."""
    landmark = get_or_ingest_landmark(req.name, req.lat, req.lon, req.wikidata_id)
    media = (
        supabase_client.table("media")
        .select("id, source, media_type, title, description, year_start, image_url, thumb_url, license, attribution, source_url, badge, confidence")
        .eq("landmark_id", landmark["id"])
        .order("confidence", desc=True)
        .execute()
        .data
    )
    return {
        "landmark": landmark,
        "media": media,
    }


@app.post("/ask")
def ask_the_past(req: AskRequest):
    """RAG endpoint for the 'Ask the Past' historical agent."""
    landmark = get_or_ingest_landmark(req.landmark_name, req.lat, req.lon)
    landmark_id = landmark["id"]

    normalized_q = f"{landmark_id}:{req.question.strip().lower()}:{req.era_filter or 'all'}"
    q_hash = hashlib.sha256(normalized_q.encode("utf-8")).hexdigest()

    try:
        cached = (
            supabase_client.table("answer_cache")
            .select("answer, citations")
            .eq("question_hash", q_hash)
            .limit(1)
            .execute()
            .data
        )
        if cached:
            return {
                "landmark_id": landmark_id,
                "landmark_name": landmark["name"],
                "answer": cached[0]["answer"],
                "citations": cached[0].get("citations", []),
                "cached": True,
            }
    except Exception:
        pass

    q_embedding = get_embeddings_batch([req.question])[0]
    rpc_res = supabase_client.rpc(
        "match_knowledge_chunks",
        {
            "query_embedding": q_embedding,
            "match_count": 5,
            "filter_landmark_id": landmark_id,
        },
    ).execute()

    chunks = rpc_res.data or []
    if not chunks:
        return {
            "landmark_id": landmark_id,
            "landmark_name": landmark["name"],
            "answer": f"I don't have enough verified archival text on {landmark['name']} to answer that specifically yet.",
            "citations": [],
            "cached": False,
        }

    context_blocks = []
    citations = []
    for idx, ch in enumerate(chunks, start=1):
        context_blocks.append(f"[Source {idx}] {ch['text']}")
        url = ch.get("source_url")
        if url and url not in citations:
            citations.append(url)

    system_prompt = (
        "You are Time-Lens, an archival historian AI inside ChronoScape 3D. "
        "Answer the user's question concisely and vividly using ONLY the provided archival sources. "
        "Do not invent dates, builders, or events not supported by the context. "
        "Cite sources inline like [Source 1] when stating specific historical facts."
    )
    user_prompt = (
        f"Landmark: {landmark['name']}\n"
        f"Era Focus: {req.era_filter or 'All Eras'}\n"
        f"Question: {req.question}\n\n"
        f"Archival Context:\n" + "\n\n".join(context_blocks)
    )

    gen_response = genai_client.models.generate_content(
        model="gemini-2.5-flash",
        contents=user_prompt,
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.2,
        ),
    )
    answer_text = gen_response.text.strip()

    try:
        supabase_client.table("answer_cache").insert({
            "landmark_id": landmark_id,
            "question_hash": q_hash,
            "question": req.question.strip(),
            "answer": answer_text,
            "citations": citations,
        }).execute()
    except Exception:
        pass

    return {
        "landmark_id": landmark_id,
        "landmark_name": landmark["name"],
        "answer": answer_text,
        "citations": citations,
        "cached": False,
    }


@app.get("/image-proxy")
def proxy_image(url: str = Query(..., description="Wikimedia image URL to proxy")):
    """Proxies Wikimedia image bytes so local ISPs cannot block image loading in Flutter."""
    if not url.startswith(("https://upload.wikimedia.org/", "https://commons.wikimedia.org/")):
        raise HTTPException(status_code=400, detail="Only Wikimedia image URLs may be proxied.")
    try:
        resp = requests.get(url, headers=WIKI_HEADERS, timeout=15)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "image/jpeg")
        return Response(
            content=resp.content,
            media_type=content_type,
            headers={"Cache-Control": "public, max-age=86400"},
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Image proxy failed: {e}")