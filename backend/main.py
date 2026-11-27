import hashlib
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor
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

app = FastAPI(title="ChronoScape 3D Backend", version="2.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ==========================================
# ARCHIVE ENDPOINTS & ALIAS MAPPINGS
# ==========================================
WIKI_URL = "https://commons.wikimedia.org/w/api.php"
EUROPEANA_URL = "https://api.europeana.eu/record/v2/search.json"
VAM_URL = "https://api.vam.ac.uk/v2/objects/search"
LOC_URL = "https://www.loc.gov/pictures/search/"
IA_URL = "https://archive.org/advancedsearch.php"
SI_URL = "https://api.si.edu/openaccess/api/v1.0/search"
HARVARD_URL = "https://api.harvardartmuseums.org/object"

HEADERS = {
    "User-Agent": "ChronoScape3D/1.0 (https://github.com/reyanmuzamil/mobile-app-project; reyanmuzamil4@gmail.com)"
}
wikipedia.set_user_agent(HEADERS["User-Agent"])

HISTORICAL_ALIASES = {
    "Badshahi Mosque": ["Badshahi Masjid", "Badshahi Mosque", "Mosque Lahore"],
    "Lahore Fort": ["Lahore Fort", "Fort of Lahore", "Citadel Lahoar"],
    "Baltit Fort": ["Baltit Fort", "Baltit Hunza", "Kanjut Fort"],
    "Altit Fort": ["Altit Fort", "Altit Hunza"],
    "Shigar Fort": ["Shigar Fort", "Shigar Baltistan"],
    "Rohtas Fort": ["Rohtas Fort", "Rhotas Fort"],
    "Derawar Fort": ["Derawar Fort", "Dirawar Fort"],
}

COLONIAL_TERM_MAP = {
    "hunza": ["Kanjut", "Hunza"],
    "baltit": ["Baltit", "Kanjut", "Hunza"],
    "altit": ["Altit", "Hunza"],
    "skardu": ["Skardo", "Baltistan", "Skardu"],
    "shigar": ["Shigar", "Baltistan"],
    "khaplu": ["Khapalu", "Baltistan", "Khaplu"],
    "gilgit": ["Gilgit", "Dardistan"],
    "chitral": ["Chitral", "Kashkar"],
    "swat": ["Swat", "Udyana"],
    "lahore": ["Lahore", "Lahoar"],
    "peshawar": ["Peshawar", "Peshawur"],
    "attabad": ["Attabad", "Hunza Valley", "Gojal"],
}

REGIONAL_FALLBACKS = {
    "Badshahi Mosque": "Lahore",
    "Lahore Fort": "Lahore",
    "Baltit Fort": "Hunza Valley",
    "Altit Fort": "Hunza Valley",
    "Shigar Fort": "Skardu Baltistan",
    "Rohtas Fort": "Jhelum Punjab",
    "Derawar Fort": "Bahawalpur Cholistan",
    "Eiffel Tower": "Paris",
    "Colosseum": "Rome",
    "Taj Mahal": "Agra",
}

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
    region_hint: Optional[str] = None
    wikidata_id: Optional[str] = None


class AskRequest(BaseModel):
    landmark_name: str
    lat: float
    lon: float
    question: str
    era_filter: Optional[int] = None


# ==========================================
# HELPER & ALIAS GENERATOR FUNCTIONS
# ==========================================
def clean_html(raw_html: str) -> str:
    if not raw_html:
        return ""
    return re.sub(r"<.*?>", "", str(raw_html)).strip()


def extract_year(raw_date: str) -> Optional[int]:
    if not raw_date:
        return None
    match = re.search(r"\b(1[4-9]\d{2}|20\d{2})\b", str(raw_date))
    return int(match.group(1)) if match else None


def first_item(val, default=""):
    if isinstance(val, list) and len(val) > 0:
        return val[0]
    return val if val else default


def generate_search_aliases(landmark_name: str) -> list[str]:
    """Generates exact, simplified, and colonial/historical aliases for both archives & RAG AI."""
    aliases = list(HISTORICAL_ALIASES.get(landmark_name, [landmark_name]))
    if landmark_name not in aliases:
        aliases.insert(0, landmark_name)

    stripped = re.sub(
        r"\b(Fort|Palace|Lake|Mosque|Masjid|Valley|Pass|Monument|Temple|Tomb)\b",
        "",
        landmark_name,
        flags=re.IGNORECASE,
    ).strip()
    if stripped and len(stripped) > 3 and stripped not in aliases:
        aliases.append(stripped)

    lower_name = landmark_name.lower()
    for key, variants in COLONIAL_TERM_MAP.items():
        if key in lower_name:
            for v in variants:
                if v not in aliases:
                    aliases.append(v)

    return aliases[:5]


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
# ALL 7 ARCHIVE FETCHERS
# ==========================================
def fetch_wikimedia_tier1(landmark_name: str, lat: float, lon: float, limit: int = 8) -> list[dict]:
    results = []
    try:
        params = {
            "action": "query",
            "generator": "geosearch",
            "ggscoord": f"{lat}|{lon}",
            "ggsradius": 500,
            "ggsnamespace": 6,
            "ggslimit": limit,
            "prop": "imageinfo",
            "iiprop": "url|extmetadata",
            "iiurlwidth": 800,
            "format": "json",
        }
        r = requests.get(WIKI_URL, params=params, headers=HEADERS, timeout=10).json()
        for page_id, page in r.get("query", {}).get("pages", {}).items():
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
            year = extract_year(ext.get("DateTimeOriginal", {}).get("value", ""))
            results.append({
                "source": "wikimedia",
                "source_id": f"geo_{page_id}",
                "title": clean_html(raw_title)[:200],
                "description": clean_html(raw_desc)[:500],
                "media_type": "painting" if (year and year < 1900) else "image",
                "year_start": year,
                "year_end": year,
                "image_url": clean_url,
                "thumb_url": info.get("thumburl", clean_url).split("?")[0],
                "license": ext.get("LicenseShortName", {}).get("value", "CC / Public Domain"),
                "attribution": clean_html(ext.get("Artist", {}).get("value", "Wikimedia"))[:150],
                "source_url": info.get("descriptionurl", ""),
                "badge": "Verified Archive",
                "confidence": 0.90,
            })
    except Exception:
        pass
    return results


def fetch_wikimedia_text(query: str, limit: int = 6) -> list[dict]:
    results = []
    try:
        params = {
            "action": "query",
            "generator": "search",
            "gsrsearch": query,
            "gsrnamespace": 6,
            "gsrlimit": limit,
            "prop": "imageinfo",
            "iiprop": "url|extmetadata",
            "iiurlwidth": 800,
            "format": "json",
        }
        r = requests.get(WIKI_URL, params=params, headers=HEADERS, timeout=10).json()
        for page_id, page in r.get("query", {}).get("pages", {}).items():
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
            year = extract_year(ext.get("DateTimeOriginal", {}).get("value", ""))
            results.append({
                "source": "wikimedia",
                "source_id": f"txt_{page_id}",
                "title": clean_html(raw_title)[:200],
                "description": clean_html(raw_desc)[:500],
                "media_type": "painting" if (year and year < 1900) else "image",
                "year_start": year,
                "year_end": year,
                "image_url": clean_url,
                "thumb_url": info.get("thumburl", clean_url).split("?")[0],
                "license": ext.get("LicenseShortName", {}).get("value", "CC / Public Domain"),
                "attribution": clean_html(ext.get("Artist", {}).get("value", "Wikimedia"))[:150],
                "source_url": info.get("descriptionurl", ""),
                "badge": "Verified Archive",
                "confidence": 0.88,
            })
    except Exception:
        pass
    return results


def fetch_europeana_tier1(landmark_name: str, limit: int = 8) -> list[dict]:
    api_key = os.environ.get("EUROPEANA_API_KEY")
    if not api_key:
        return []
    results = []
    try:
        resp = requests.get(
            EUROPEANA_URL,
            params={"wskey": api_key, "query": f'"{landmark_name}"', "qf": "TYPE:IMAGE", "media": "true", "rows": limit},
            timeout=10,
        ).json()
        for item in resp.get("items", []):
            full_url = first_item(item.get("edmIsShownBy"), "")
            preview_url = first_item(item.get("edmPreview"), "")
            image_url = full_url if full_url.lower().endswith((".jpg", ".jpeg", ".png", ".webp")) else preview_url
            if not image_url:
                continue
            provider = first_item(item.get("dataProvider"), "Europeana")
            year = extract_year(str(first_item(item.get("year"), "")))
            results.append({
                "source": "europeana",
                "source_id": item.get("id", ""),
                "title": str(first_item(item.get("title"), landmark_name))[:200],
                "description": str(first_item(item.get("dcDescription"), ""))[:500],
                "media_type": "painting" if (year and year < 1900) else "image",
                "year_start": year,
                "year_end": year,
                "image_url": image_url,
                "thumb_url": preview_url or image_url,
                "license": str(first_item(item.get("rights"), "Public Domain")),
                "attribution": str(provider)[:150],
                "source_url": item.get("guid", ""),
                "badge": "British Library" if "british library" in provider.lower() else "Verified Archive",
                "confidence": 0.95,
            })
    except Exception:
        pass
    return results


def fetch_vam(query: str, limit: int = 6) -> list[dict]:
    results = []
    try:
        resp = requests.get(
            VAM_URL,
            params={"q": query, "images_exist": 1, "page_size": limit},
            headers=HEADERS,
            timeout=10,
        ).json()
        for rec in resp.get("records", []):
            img_id = rec.get("_primaryImageId")
            sys_num = rec.get("systemNumber", "")
            if not img_id:
                continue
            image_url = f"https://framemark.vam.ac.uk/collections/{img_id}/full/!800,800/0/default.jpg"
            thumb_url = f"https://framemark.vam.ac.uk/collections/{img_id}/full/!300,300/0/default.jpg"
            title = rec.get("_primaryTitle") or rec.get("objectType") or query
            place = rec.get("_primaryPlace", "")
            year = extract_year(str(rec.get("_primaryDate", "")))
            results.append({
                "source": "vam",
                "source_id": sys_num or img_id,
                "title": clean_html(title)[:200],
                "description": f"{rec.get('objectType', 'Artifact')} from {place} ({rec.get('_primaryDate', 'Historical')})"[:500],
                "media_type": "painting",
                "year_start": year,
                "year_end": year,
                "image_url": image_url,
                "thumb_url": thumb_url,
                "license": "V&A Open Access / Non-Commercial",
                "attribution": "Victoria and Albert Museum, London",
                "source_url": f"https://collections.vam.ac.uk/item/{sys_num}",
                "badge": "V&A Museum",
                "confidence": 0.94,
            })
    except Exception:
        pass
    return results


def fetch_loc(query: str, limit: int = 6) -> list[dict]:
    results = []
    try:
        resp = requests.get(
            LOC_URL,
            params={"q": query, "fo": "json", "c": limit},
            headers=HEADERS,
            timeout=10,
        ).json()
        for item in resp.get("results", []):
            img_obj = item.get("image", {})
            full_url = img_obj.get("full") or img_obj.get("thumb") or ""
            thumb_url = img_obj.get("thumb") or full_url
            if not full_url:
                continue
            if full_url.startswith("//"):
                full_url = "https:" + full_url
            if thumb_url.startswith("//"):
                thumb_url = "https:" + thumb_url
            pk = str(item.get("pk") or item.get("id") or full_url[-30:])
            year = extract_year(str(item.get("created_published_date", "")))
            results.append({
                "source": "loc",
                "source_id": pk,
                "title": clean_html(item.get("title", query))[:200],
                "description": clean_html(item.get("medium") or item.get("notes") or "")[:500],
                "media_type": "painting" if (year and year < 1900) else "image",
                "year_start": year,
                "year_end": year,
                "image_url": full_url,
                "thumb_url": thumb_url,
                "license": "No known restrictions on publication",
                "attribution": "Library of Congress Prints & Photographs",
                "source_url": item.get("links", {}).get("item", "https://www.loc.gov/pictures/"),
                "badge": "Library of Congress",
                "confidence": 0.93,
            })
    except Exception:
        pass
    return results


def fetch_internet_archive(query: str, limit: int = 6) -> list[dict]:
    results = []
    try:
        resp = requests.get(
            IA_URL,
            params={
                "q": f"({query}) AND mediatype:image",
                "fl[]": ["identifier", "title", "description", "date", "creator"],
                "rows": limit,
                "output": "json",
            },
            headers=HEADERS,
            timeout=10,
        ).json()
        for doc in resp.get("response", {}).get("docs", []):
            ident = doc.get("identifier")
            if not ident:
                continue
            image_url = f"https://archive.org/services/img/{ident}"
            year = extract_year(str(doc.get("date", "")))
            results.append({
                "source": "internet_archive",
                "source_id": ident,
                "title": clean_html(first_item(doc.get("title"), query))[:200],
                "description": clean_html(first_item(doc.get("description"), ""))[:500],
                "media_type": "painting" if (year and year < 1900) else "image",
                "year_start": year,
                "year_end": year,
                "image_url": image_url,
                "thumb_url": image_url,
                "license": "Public Domain / Open Archive",
                "attribution": clean_html(first_item(doc.get("creator"), "Internet Archive"))[:150],
                "source_url": f"https://archive.org/details/{ident}",
                "badge": "Internet Archive",
                "confidence": 0.88,
            })
    except Exception:
        pass
    return results


def fetch_smithsonian(query: str, limit: int = 6) -> list[dict]:
    api_key = os.environ.get("GOV_DATA_") or os.environ.get("SMITHSONIAN_API_KEY")
    if not api_key:
        return []
    results = []
    try:
        resp = requests.get(
            SI_URL,
            params={"q": f"{query} AND online_media_type:Images", "rows": limit, "api_key": api_key},
            timeout=10,
        ).json()
        for row in resp.get("response", {}).get("rows", []):
            content = row.get("content", {})
            desc_non = content.get("descriptiveNonRepeating", {})
            media_list = desc_non.get("online_media", {}).get("media", [])
            if not media_list:
                continue
            image_url = media_list[0].get("content") or media_list[0].get("thumbnail")
            if not image_url:
                continue
            freetext = content.get("freetext", {})
            date_str = first_item(freetext.get("date", []), {})
            year = extract_year(date_str.get("content", "") if isinstance(date_str, dict) else "")
            results.append({
                "source": "smithsonian",
                "source_id": row.get("id", image_url[-25:]),
                "title": clean_html(row.get("title", query))[:200],
                "description": f"Smithsonian {desc_non.get('data_source', 'Open Access Collection')}"[:500],
                "media_type": "painting",
                "year_start": year,
                "year_end": year,
                "image_url": image_url,
                "thumb_url": media_list[0].get("thumbnail") or image_url,
                "license": "CC0 Public Domain",
                "attribution": desc_non.get("data_source", "Smithsonian Institution")[:150],
                "source_url": desc_non.get("record_link", "https://www.si.edu/openaccess"),
                "badge": "Smithsonian CC0",
                "confidence": 0.95,
            })
    except Exception:
        pass
    return results


def fetch_harvard(query: str, limit: int = 6) -> list[dict]:
    api_key = os.environ.get("HARVARD_API_KEY")
    if not api_key:
        return []
    results = []
    try:
        resp = requests.get(
            HARVARD_URL,
            params={"apikey": api_key, "keyword": query, "hasimage": 1, "size": limit},
            timeout=10,
        ).json()
        for rec in resp.get("records", []):
            image_url = rec.get("primaryimageurl")
            if not image_url:
                images = rec.get("images") or []
                if images:
                    image_url = images[0].get("baseimageurl")
            if not image_url:
                continue

            obj_id = str(rec.get("id") or rec.get("objectnumber") or image_url[-25:])
            people = rec.get("people") or []
            artist = people[0].get("name") if people else "Harvard Art Museums"
            year = extract_year(str(rec.get("dated", "")))
            desc_parts = [rec.get("classification", ""), rec.get("medium", ""), rec.get("dated", "")]
            desc = " | ".join([p for p in desc_parts if p])

            results.append({
                "source": "harvard",
                "source_id": obj_id,
                "title": clean_html(rec.get("title", query))[:200],
                "description": clean_html(desc)[:500],
                "media_type": "painting",
                "year_start": year,
                "year_end": year,
                "image_url": image_url,
                "thumb_url": f"{image_url}?height=300&width=300",
                "license": rec.get("creditline", "Harvard Art Museums Open Access")[:120],
                "attribution": clean_html(artist)[:150],
                "source_url": rec.get("url", "https://harvardartmuseums.org/collections"),
                "badge": "Harvard Art Museums",
                "confidence": 0.95,
            })
    except Exception:
        pass
    return results


# ==========================================
# 4-TIER FALLBACK PIPELINE & ALIAS-AWARE WIKIPEDIA CHUNKER
# ==========================================
def fetch_media_4_tier(landmark_name: str, lat: float, lon: float, region_hint: Optional[str] = None) -> tuple[list[dict], str]:
    all_items = []
    seen = set()

    def _add(items: list[dict], override_badge: str = None, is_regional: bool = False):
        for it in items:
            key = (it["source"], it["source_id"])
            if key in seen:
                continue
            seen.add(key)
            if override_badge:
                it["badge"] = override_badge
            if is_regional:
                it["description"] = f"[Surrounding Area Fallback] {it['description']}"[:500]
                it["confidence"] = 0.65
            all_items.append(it)

    # Tier 1: Exact 500m Geosearch + Europeana
    _add(fetch_wikimedia_tier1(landmark_name, lat, lon) + fetch_europeana_tier1(landmark_name))
    if len(all_items) >= 3:
        return all_items, "Exact landmark archival records loaded."

    # Tier 2: Parallel Multi-Archive Search with Generated Aliases
    aliases = generate_search_aliases(landmark_name)
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = []
        for alias in aliases[:3]:
            futures.append(pool.submit(fetch_wikimedia_text, alias, 4))
            futures.append(pool.submit(fetch_vam, alias, 4))
            futures.append(pool.submit(fetch_loc, alias, 4))
            futures.append(pool.submit(fetch_internet_archive, alias, 4))
            futures.append(pool.submit(fetch_smithsonian, alias, 4))
            futures.append(pool.submit(fetch_harvard, alias, 4))
        for fut in futures:
            _add(fut.result())

    if len(all_items) >= 2:
        return all_items, "Multi-archive museum & colonial records loaded."

    # Tier 3: Regional / City-Level Fallback ('Estimated (Amber)')
    region_query = region_hint or REGIONAL_FALLBACKS.get(landmark_name)
    if not region_query and "," in landmark_name:
        region_query = landmark_name.split(",")[-1].strip()

    if region_query:
        with ThreadPoolExecutor(max_workers=5) as pool:
            for fut in (
                pool.submit(fetch_vam, region_query, 4),
                pool.submit(fetch_loc, region_query, 4),
                pool.submit(fetch_internet_archive, region_query, 4),
                pool.submit(fetch_smithsonian, region_query, 4),
                pool.submit(fetch_harvard, region_query, 4),
            ):
                _add(fut.result(), override_badge="Estimated (Amber)", is_regional=True)

    if all_items:
        return all_items, f"No verified archival images found for this exact spot yet — showing nearest regional records ({region_query})."

    # Tier 4: Graceful Empty State
    return [], "No verified archival images found for this exact spot yet — showing historical summary and 3D map."


def fetch_and_chunk_wikipedia(landmark_name: str, chunk_size: int = 800, overlap: int = 150) -> tuple[str, str, list[dict]]:
    """Tries exact name first, then loops through generated historical/colonial aliases if needed."""
    aliases = generate_search_aliases(landmark_name)
    page = None
    last_err = None

    for candidate in aliases:
        try:
            page = wikipedia.page(candidate, auto_suggest=True)
            break
        except Exception as e:
            last_err = e

    if not page:
        raise RuntimeError(f"No Wikipedia page found across aliases {aliases}: {last_err}")

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


def get_or_ingest_landmark(
    name: str, lat: float, lon: float, wikidata_id: Optional[str] = None, region_hint: Optional[str] = None
) -> tuple[dict, str]:
    existing = (
        supabase_client.table("landmarks")
        .select("*")
        .ilike("name", name.strip())
        .limit(1)
        .execute()
        .data
    )
    if existing:
        return existing[0], "Loaded from ChronoScape archive cache."

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

    imgs, notice_msg = fetch_media_4_tier(name, lat, lon, region_hint=region_hint)
    if imgs:
        media_vecs = get_embeddings_batch([f"{i['title']} - {i['description']}".strip() for i in imgs])
        for img, vec in zip(imgs, media_vecs):
            img["landmark_id"] = landmark_id
            img["embedding"] = vec
        supabase_client.table("media").insert(imgs).execute()

    return landmark, notice_msg


# ==========================================
# API ENDPOINTS
# ==========================================
@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/explore")
def explore_landmark(req: ExploreRequest):
    landmark, notice = get_or_ingest_landmark(
        req.name, req.lat, req.lon, wikidata_id=req.wikidata_id, region_hint=req.region_hint
    )
    media = (
        supabase_client.table("media")
        .select("id, source, media_type, title, description, year_start, image_url, thumb_url, license, attribution, source_url, badge, confidence")
        .eq("landmark_id", landmark["id"])
        .order("confidence", desc=True)
        .execute()
        .data
    )
    if not media:
        notice = "No verified archival images found for this exact spot yet — showing historical summary and 3D map."
    elif any(m.get("badge") == "Estimated (Amber)" for m in media):
        notice = "No verified archival images found for this exact spot yet — showing nearest regional records."

    return {
        "landmark": landmark,
        "media": media,
        "aliases_used": generate_search_aliases(landmark["name"]),
        "notice": notice,
    }


@app.post("/ask")
def ask_the_past(req: AskRequest):
    landmark, _ = get_or_ingest_landmark(req.landmark_name, req.lat, req.lon)
    landmark_id = landmark["id"]
    aliases = generate_search_aliases(landmark["name"])

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

    # Enrich embedding query with historical aliases so colonial terms match chunks
    enriched_query = f"{req.question} ({', '.join(aliases[:3])})"
    q_embedding = get_embeddings_batch([enriched_query])[0]
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
        "Note that historical sources may refer to the landmark or region using colonial or local aliases listed below. "
        "Do not invent dates, builders, or events not supported by the context. "
        "Cite sources inline like [Source 1] when stating specific historical facts."
    )
    user_prompt = (
        f"Landmark: {landmark['name']}\n"
        f"Known Historical / Colonial Aliases: {', '.join(aliases)}\n"
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
def proxy_image(url: str = Query(..., description="Archival image URL to proxy")):
    """Proxies archival image bytes so local ISPs cannot block image loading in Flutter."""
    allowed_prefixes = (
        "https://upload.wikimedia.org/",
        "https://commons.wikimedia.org/",
        "https://framemark.vam.ac.uk/",
        "https://tile.loc.gov/",
        "https://archive.org/",
        "https://ids.si.edu/",
        "https://nrs.harvard.edu/",
        "https://ids.lib.harvard.edu/",
    )
    if not url.startswith(allowed_prefixes):
        raise HTTPException(status_code=400, detail="Unsupported archive domain for proxy.")
    try:
        resp = requests.get(url, headers=HEADERS, timeout=15)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "image/jpeg")
        return Response(
            content=resp.content,
            media_type=content_type,
            headers={"Cache-Control": "public, max-age=86400"},
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Image proxy failed: {e}")