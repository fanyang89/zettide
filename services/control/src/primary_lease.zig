const lease = @import("zettide_data_service_contracts").primary_lease;

pub const Id = @import("zettide_data_service_contracts").Id;
pub const duration_ms = lease.duration_ms;
pub const renew_after_ms = lease.renew_after_ms;
pub const early_stop_margin_ms = lease.early_stop_margin_ms;
pub const minimum_ready_remaining_ms = lease.minimum_ready_remaining_ms;
pub const Token = lease.Token;
pub const Window = lease.Window;
pub const Runtime = lease.Runtime;
