from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from . import __version__
from .config import CORS_ORIGINS, HOST, PORT
from .routers import admin, auth, health, pan, services, settings

app = FastAPI(title="RexHub Server", version=__version__)

# App 与管理台都是同源访问，默认不开放跨域；如需网页端调用可配置 REXHUB_CORS_ORIGINS。
if CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=CORS_ORIGINS,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type"],
    )

app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(admin.router)
app.include_router(pan.router)
app.include_router(services.router)
app.include_router(settings.router)


@app.get("/")
async def root() -> dict:
    return {
        "name": "RexHub Server",
        "version": __version__,
        "admin": "/admin",
        "docs": "/docs",
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host=HOST, port=PORT, reload=True)
