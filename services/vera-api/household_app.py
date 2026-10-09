from fastapi import FastAPI
from fastapi.responses import JSONResponse

from routers.household import router
from routers.household_runtime import lifespan

app = FastAPI(title="Household inbox gateway", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(router)


@app.get("/health")
async def health() -> JSONResponse:
    gateway = getattr(app.state, "household_gateway", None)
    return JSONResponse({"ok": gateway is not None}, status_code=200 if gateway else 503)
