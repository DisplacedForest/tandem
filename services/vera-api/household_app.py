from fastapi import FastAPI
from fastapi.responses import JSONResponse

from routers.household_gateway import router
from routers.household_oauth import lifespan, router as oauth_router

app = FastAPI(title="Household inbox gateway", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(router)
app.include_router(oauth_router)


@app.get("/health")
async def health() -> JSONResponse:
    gateway = getattr(app.state, "household_gateway", None)
    return JSONResponse({"ok": gateway is not None}, status_code=200 if gateway else 503)
