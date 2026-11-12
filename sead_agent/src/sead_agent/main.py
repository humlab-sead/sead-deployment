"""
The SEAD agent's web service. Run it with

    uvicorn --factory sead_agent.main:create_app

as a single process: conversations and the turns waiting on a browser are kept in memory,
so a second worker would not know about the first one's.
"""
import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .agent_service import SeadAgentService
from .config import Settings


def create_app(settings=None, model=None):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    settings = settings or Settings.from_env()

    app = FastAPI(title="SEAD agent", docs_url=None, redoc_url=None, openapi_url=None)
    #Which origins may post is decided per request (SEAD_AGENT_ALLOWED_ORIGINS), with an
    #answer the chatbox can show - so CORS itself lets every origin through
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET", "POST"], allow_headers=["*"])

    service = SeadAgentService(settings, model=model)
    service.register(app)
    app.state.sead_agent = service
    return app
