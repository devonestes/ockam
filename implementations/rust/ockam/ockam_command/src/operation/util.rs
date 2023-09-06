use miette::miette;
use tokio_retry::strategy::FixedInterval;
use tokio_retry::Retry;

use ockam_api::cloud::operation::Operation;
use ockam_api::cloud::ORCHESTRATOR_AWAIT_TIMEOUT_MS;

use crate::util::api::CloudOpts;
use crate::util::{api, RpcBuilder};
use crate::CommandGlobalOpts;
use crate::Result;

pub async fn check_for_completion<'a>(
    ctx: &ockam::Context,
    opts: &CommandGlobalOpts,
    api_node: &str,
    operation_id: &str,
) -> miette::Result<()> {
    let retry_strategy =
        FixedInterval::from_millis(5000).take(ORCHESTRATOR_AWAIT_TIMEOUT_MS / 5000);

    let spinner_option = opts.terminal.progress_spinner();
    if let Some(spinner) = spinner_option.as_ref() {
        spinner.set_message("Configuring project...");
    }
    let route = CloudOpts::route();
    let operation = Retry::spawn(retry_strategy.clone(), || async {
        let mut rpc = RpcBuilder::new(ctx, opts, api_node).build();

        // Handle the operation show request result
        // so we can provide better errors in the case orchestrator does not respond timely
        let result: Result<Operation> = rpc.ask(api::operation::show(operation_id, &route)).await;
        result.and_then(|o| {
            if o.is_completed() {
                Ok(o)
            } else {
                Err(miette!("Operation timed out. Please try again.").into())
            }
        })
    })
    .await?;

    if let Some(spinner) = spinner_option.as_ref() {
        spinner.finish_and_clear();
    }

    if operation.is_successful() {
        Ok(())
    } else {
        Err(miette!("Operation failed. Please try again."))
    }
}
