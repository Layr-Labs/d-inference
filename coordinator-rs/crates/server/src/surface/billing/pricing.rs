use serde::Serialize;
use sqlx::Row;

use super::{error::BillingError, money::format_usd, store::BillingStore};

const MAX_MODEL_BYTES: usize = 256;
const FALLBACK_INPUT_PRICE: i64 = 50_000;
const FALLBACK_OUTPUT_PRICE: i64 = 200_000;

#[derive(Clone, Debug)]
pub(super) struct PricingService {
    store: BillingStore,
}

impl PricingService {
    pub(super) fn new(store: BillingStore) -> Self {
        Self { store }
    }

    pub(super) async fn list_platform(&self) -> Result<PricingResponse, BillingError> {
        let rows = sqlx::query(
            r#"
            SELECT model, input_price, output_price
            FROM public.model_prices
            WHERE account_id = 'platform'
            ORDER BY model
            "#,
        )
        .fetch_all(self.store.pool())
        .await
        .map_err(|error| BillingError::internal("list platform pricing", error))?;
        let mut prices = Vec::with_capacity(rows.len());
        for row in rows {
            let input = row.get::<i64, _>("input_price");
            let output = row.get::<i64, _>("output_price");
            validate_prices(input, output)?;
            prices.push(ModelPriceView {
                model: row.get("model"),
                input_price: input,
                output_price: output,
                input_usd: format_usd(input),
                output_usd: format_usd(output),
            });
        }
        Ok(PricingResponse {
            prices,
            fallback_input_price: FALLBACK_INPUT_PRICE,
            fallback_output_price: FALLBACK_OUTPUT_PRICE,
            fallback_input_usd: format_usd(FALLBACK_INPUT_PRICE),
            fallback_output_usd: format_usd(FALLBACK_OUTPUT_PRICE),
        })
    }

    pub(super) async fn set(
        &self,
        owner_account_id: &str,
        model: &str,
        input_price: i64,
        output_price: i64,
    ) -> Result<ModelPriceView, BillingError> {
        let model = validate_model(model)?;
        validate_prices(input_price, output_price)?;
        let mut transaction = self.store.begin("set model pricing").await?;
        sqlx::query(
            r#"
            INSERT INTO public.model_prices (
                account_id, model, input_price, output_price, revision, updated_at
            )
            VALUES ($1, $2, $3, $4, 1, NOW())
            ON CONFLICT (account_id, model) DO UPDATE SET
                input_price = EXCLUDED.input_price,
                output_price = EXCLUDED.output_price,
                revision = model_prices.revision + 1,
                updated_at = NOW()
            "#,
        )
        .bind(owner_account_id)
        .bind(&model)
        .bind(input_price)
        .bind(output_price)
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("set model pricing", error))?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(ModelPriceView {
            model,
            input_price,
            output_price,
            input_usd: format_usd(input_price),
            output_usd: format_usd(output_price),
        })
    }

    pub(super) async fn delete(
        &self,
        owner_account_id: &str,
        model: &str,
    ) -> Result<String, BillingError> {
        let model = validate_model(model)?;
        let mut transaction = self.store.begin("delete model pricing").await?;
        let deleted: Option<String> = sqlx::query_scalar(
            "DELETE FROM public.model_prices WHERE account_id = $1 AND model = $2 RETURNING model",
        )
        .bind(owner_account_id)
        .bind(&model)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("delete model pricing", error))?;
        if deleted.is_none() {
            return Err(BillingError::not_found(
                "model price owned by this account was not found",
            ));
        }
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(model)
    }
}

fn validate_model(model: &str) -> Result<String, BillingError> {
    let model = model.trim();
    if model.is_empty() || model.len() > MAX_MODEL_BYTES || model.chars().any(char::is_control) {
        return Err(BillingError::bad_request(
            "model must be 1-256 visible bytes",
        ));
    }
    Ok(model.to_owned())
}

fn validate_prices(input: i64, output: i64) -> Result<(), BillingError> {
    if input <= 0 || output <= 0 {
        return Err(BillingError::bad_request(
            "input_price and output_price must be positive micro-USD per million tokens",
        ));
    }
    Ok(())
}

#[derive(Debug, Serialize)]
pub(super) struct PricingResponse {
    pub prices: Vec<ModelPriceView>,
    pub fallback_input_price: i64,
    pub fallback_output_price: i64,
    pub fallback_input_usd: String,
    pub fallback_output_usd: String,
}

#[derive(Debug, Serialize)]
pub(super) struct ModelPriceView {
    pub model: String,
    pub input_price: i64,
    pub output_price: i64,
    pub input_usd: String,
    pub output_usd: String,
}
