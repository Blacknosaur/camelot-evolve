use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Upsert,
    Delete,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Mutation {
    pub mutation_id: Uuid,
    pub entity_id: Uuid,
    pub entity_type: String,
    pub operation: Operation,
    pub base_version: Option<u64>,
    pub parent_id: Option<Uuid>,
    pub payload: Value,
    pub client_timestamp: String,
}

