# Panel IPSA

Panel de análisis de las acciones del IPSA (Bolsa de Santiago): Top 10 alzas y
bajas en los últimos 12 meses, 30 días y 3 días hábiles, más la tabla completa
de los componentes del índice.

**Sitio:** https://rafaelmontes10-ctrl.github.io/panel-ipsa/

## Cómo se actualiza

- `update_panel.ps1` descarga precios de cierre diarios desde Yahoo Finance
  (tickers `.SN`) y genera el HTML.
- GitHub Actions (`.github/workflows/pages.yml`) lo ejecuta de lunes a viernes
  después del cierre y publica el resultado en GitHub Pages.
- Para actualizar a mano: pestaña **Actions → Publicar Panel IPSA → Run workflow**.
- En Windows, el mismo script sin parámetros genera `panel.html` local y lo abre.

Uso informativo; no constituye recomendación de inversión.
