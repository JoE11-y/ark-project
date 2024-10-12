#[starknet::component]
pub mod OrderbookComponent {
    use ark_common::protocol::order_database::{
        order_read, order_status_read, order_write, order_status_write, order_type_read
    };
    use ark_common::protocol::order_types::{
        OrderStatus, OrderTrait, OrderType, CancelInfo, FulfillInfo, ExecutionValidationInfo,
        ExecutionInfo, RouteType, OptionU256
    };
    use ark_common::protocol::order_v1::OrderV1;
    use core::debug::PrintTrait;
    use core::option::OptionTrait;
    use core::result::ResultTrait;
    use core::starknet::event::EventEmitter;
    use core::traits::Into;
    use core::traits::TryInto;
    use core::zeroable::Zeroable;
    use starknet::ContractAddress;
    use starknet::storage::Map;

    use super::super::interface::{IOrderbook, IOrderbookAction, orderbook_errors};

    const EXTENSION_TIME_IN_SECONDS: u64 = 600;
    const AUCTION_ACCEPTING_TIME_SECS: u64 = 172800;
    /// Storage struct for the Orderbook component.
    #[storage]
    struct Storage {
        /// Mapping of broker addresses to their whitelisted status.
        /// Represented as felt252, set to 1 if the broker is registered.
        brokers: Map<felt252, felt252>,
        /// Mapping of token_hash to order_hash.
        token_listings: Map<felt252, felt252>,
        /// Mapping of token_hash to auction details (order_hash and end_date, auction_offer_count).
        auctions: Map<felt252, (felt252, u64, u256)>,
        /// Mapping of auction offer order_hash to auction listing order_hash.
        auction_offers: Map<felt252, felt252>,
        /// Mapping of erc20s buy orderhash to the order (price, quantity)
        buy_orders: Map<felt252, (u256, u256)>,
        /// Mapping of erc20s sell orderhash to the order (price, quantity)
        sell_orders: Map<felt252, (u256, u256)>
    }

    // *************************************************************************
    // EVENTS
    // *************************************************************************

    /// Events emitted by the Orderbook contract.
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        OrderPlaced: OrderPlaced,
        OrderExecuted: OrderExecuted,
        OrderCancelled: OrderCancelled,
        RollbackStatus: RollbackStatus,
        OrderFulfilled: OrderFulfilled,
    }

    // precision for erc20 price division
    const PRECISION: u256 = 1000000000000000000;

    // must be increased when `OrderPlaced` content change
    pub const ORDER_PLACED_EVENT_VERSION: u8 = 1;
    /// Event for when an order is placed.
    #[derive(Drop, starknet::Event)]
    pub struct OrderPlaced {
        #[key]
        order_hash: felt252,
        #[key]
        order_version: felt252,
        #[key]
        order_type: OrderType,
        ///
        version: u8,
        // The order that was cancelled by this order.
        cancelled_order_hash: Option<felt252>,
        // The full order serialized.
        order: OrderV1,
    }

    // must be increased when `OrderExecuted` content change
    pub const ORDER_EXECUTED_EVENT_VERSION: u8 = 2;
    /// Event for when an order is executed.
    #[derive(Drop, starknet::Event)]
    pub struct OrderExecuted {
        #[key]
        order_hash: felt252,
        #[key]
        order_status: OrderStatus,
        #[key]
        order_type: OrderType,
        ///
        version: u8,
        transaction_hash: felt252,
        from: ContractAddress,
        to: ContractAddress,
    }

    // must be increased when `OrderPlaced` content change
    pub const ORDER_CANCELLED_EVENT_VERSION: u8 = 1;
    /// Event for when an order is cancelled.
    #[derive(Drop, starknet::Event)]
    pub struct OrderCancelled {
        #[key]
        order_hash: felt252,
        #[key]
        reason: felt252,
        #[key]
        order_type: OrderType,
        version: u8,
    }

    // must be increased when `RollbackStatus` content change
    pub const ROLLBACK_STATUS_EVENT_VERSION: u8 = 1;
    /// Event for when an order has been rollbacked to placed.
    #[derive(Drop, starknet::Event)]
    pub struct RollbackStatus {
        #[key]
        order_hash: felt252,
        #[key]
        reason: felt252,
        #[key]
        order_type: OrderType,
        ///
        version: u8,
    }

    // must be increased when `OrderFulfilled` content change
    pub const ORDER_FULFILLED_EVENT_VERSION: u8 = 1;
    /// Event for when an order is fulfilled.
    #[derive(Drop, starknet::Event)]
    pub struct OrderFulfilled {
        #[key]
        order_hash: felt252,
        #[key]
        fulfiller: ContractAddress,
        #[key]
        related_order_hash: Option<felt252>,
        #[key]
        order_type: OrderType,
        ///
        version: u8,
    }

    pub trait OrderbookHooksCreateOrderTrait<TContractState> {
        fn before_create_order(ref self: ComponentState<TContractState>, order: OrderV1) {}
        fn after_create_order(ref self: ComponentState<TContractState>, order: OrderV1) {}
    }

    pub trait OrderbookHooksCancelOrderTrait<TContractState> {
        fn before_cancel_order(ref self: ComponentState<TContractState>, cancel_info: CancelInfo) {}
        fn after_cancel_order(ref self: ComponentState<TContractState>, cancel_info: CancelInfo) {}
    }

    pub trait OrderbookHooksFulfillOrderTrait<TContractState> {
        fn before_fulfill_order(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo
        ) {}
        fn after_fulfill_order(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo
        ) {}
    }

    pub trait OrderbookHooksValidateOrderExecutionTrait<TContractState> {
        fn before_validate_order_execution(
            ref self: ComponentState<TContractState>, info: ExecutionValidationInfo
        ) {}
        fn after_validate_order_execution(
            ref self: ComponentState<TContractState>, info: ExecutionValidationInfo
        ) {}
    }

    #[embeddable_as(OrderbookImpl)]
    pub impl Orderbook<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of IOrderbook<ComponentState<TContractState>> {
        /// Retrieves the type of an order using its hash.
        /// # View
        fn get_order_type(self: @ComponentState<TContractState>, order_hash: felt252) -> OrderType {
            let order_type_option = order_type_read(order_hash);
            if order_type_option.is_none() {
                panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND);
            }
            order_type_option.unwrap().into()
        }

        /// Retrieves the status of an order using its hash.
        /// # View
        fn get_order_status(
            self: @ComponentState<TContractState>, order_hash: felt252
        ) -> OrderStatus {
            let status = order_status_read(order_hash);
            if status.is_none() {
                panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND);
            }
            status.unwrap().into()
        }

        /// Retrieves the auction end date
        /// # View
        fn get_auction_expiration(
            self: @ComponentState<TContractState>, order_hash: felt252
        ) -> u64 {
            let order = order_read::<OrderV1>(order_hash);
            if (order.is_none()) {
                panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND);
            }
            let token_hash = order.unwrap().compute_token_hash();
            let (_, auction_end_date, _b) = self.auctions.read(token_hash);
            auction_end_date
        }

        /// Retrieves the order using its hash.
        /// # View
        fn get_order(self: @ComponentState<TContractState>, order_hash: felt252) -> OrderV1 {
            let order = order_read(order_hash);
            if (order.is_none()) {
                panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND);
            }
            order.unwrap()
        }

        /// Retrieves the order hash using its token hash.
        /// # View
        fn get_order_hash(self: @ComponentState<TContractState>, token_hash: felt252) -> felt252 {
            let order_hash = self.token_listings.read(token_hash);
            if (order_hash.is_zero()) {
                panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND);
            }
            order_hash
        }
    }

    pub impl OrderbookActionImpl<
        TContractState,
        +HasComponent<TContractState>,
        impl HooksCreateOrder: OrderbookHooksCreateOrderTrait<TContractState>,
        impl HooksCancelOrder: OrderbookHooksCancelOrderTrait<TContractState>,
        impl HooksFulfillOrder: OrderbookHooksFulfillOrderTrait<TContractState>,
        impl HooksValidateOrder: OrderbookHooksValidateOrderExecutionTrait<TContractState>,
    > of IOrderbookAction<ComponentState<TContractState>> {
        fn validate_order_execution(
            ref self: ComponentState<TContractState>, info: ExecutionValidationInfo
        ) {
            HooksValidateOrder::before_validate_order_execution(ref self, info);
            order_status_write(info.order_hash, OrderStatus::Executed);
            let order_status = order_status_read(info.order_hash).unwrap();
            let order_type = order_type_read(info.order_hash).unwrap();
            self
                .emit(
                    OrderExecuted {
                        order_hash: info.order_hash,
                        order_status,
                        order_type,
                        transaction_hash: info.transaction_hash,
                        from: info.from,
                        to: info.to,
                        version: ORDER_EXECUTED_EVENT_VERSION,
                    }
                );

            HooksValidateOrder::after_validate_order_execution(ref self, info);
        }

        /// Submits and places an order to the orderbook if the order is valid.
        fn create_order(ref self: ComponentState<TContractState>, order: OrderV1) {
            HooksCreateOrder::before_create_order(ref self, order);
            let block_ts = starknet::get_block_timestamp();
            let validation = order.validate_common_data(block_ts);
            if validation.is_err() {
                panic_with_felt252(validation.unwrap_err().into());
            }
            let order_type = order
                .validate_order_type()
                .expect(orderbook_errors::ORDER_INVALID_DATA);
            let order_hash = order.compute_order_hash();
            assert(order_status_read(order_hash).is_none(), orderbook_errors::ORDER_ALREADY_EXISTS);
            match order_type {
                OrderType::Listing => {
                    let _ = self._create_listing_order(order, order_type, order_hash);
                },
                OrderType::Auction => { self._create_auction(order, order_type, order_hash); },
                OrderType::Offer => { self._create_offer(order, order_type, order_hash); },
                OrderType::CollectionOffer => {
                    self._create_collection_offer(order, order_type, order_hash);
                },
                OrderType::LimitBuy => { self._create_limit_order(order, order_type, order_hash); },
                OrderType::LimitSell => { self._create_limit_order(order, order_type, order_hash); }
            };

            HooksCreateOrder::after_create_order(ref self, order);
        }

        fn cancel_order(ref self: ComponentState<TContractState>, cancel_info: CancelInfo) {
            HooksCancelOrder::before_cancel_order(ref self, cancel_info);
            let order_hash = cancel_info.order_hash;
            let order_option = order_read::<OrderV1>(order_hash);
            assert(order_option.is_some(), orderbook_errors::ORDER_NOT_FOUND);
            let order = order_option.unwrap();
            assert(order.offerer == cancel_info.canceller, 'not the same offerrer');
            match order_status_read(order_hash) {
                Option::Some(s) => assert(
                    s == OrderStatus::Open, orderbook_errors::ORDER_FULFILLED
                ),
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };
            let block_ts = starknet::get_block_timestamp();
            let order_type = match order_type_read(order_hash) {
                Option::Some(order_type) => {
                    if order_type == OrderType::Auction {
                        let auction_token_hash = order.compute_token_hash();
                        let (_, auction_end_date, _) = self.auctions.read(auction_token_hash);
                        assert(
                            block_ts <= auction_end_date, orderbook_errors::ORDER_AUCTION_IS_EXPIRED
                        );
                        self.auctions.write(auction_token_hash, (0, 0, 0));
                    } else if order_type == OrderType::LimitBuy {
                        self.buy_orders.write(order_hash, (0, 0));
                    } else if order_type == OrderType::LimitSell {
                        self.sell_orders.write(order_hash, (0, 0));
                    } else {
                        assert(block_ts < order.end_date, orderbook_errors::ORDER_IS_EXPIRED);
                        if order_type == OrderType::Listing {
                            let order_hash = order.compute_token_hash();
                            self.token_listings.write(order_hash, 0);
                        }
                    };

                    order_type
                },
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND)
            };

            // Cancel order
            order_status_write(order_hash, OrderStatus::CancelledUser);
            self
                .emit(
                    OrderCancelled {
                        order_hash,
                        reason: OrderStatus::CancelledUser.into(),
                        order_type,
                        version: ORDER_CANCELLED_EVENT_VERSION,
                    }
                );

            HooksCancelOrder::after_cancel_order(ref self, cancel_info);
        }

        fn fulfill_order(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo
        ) -> Option::<ExecutionInfo> {
            HooksFulfillOrder::before_fulfill_order(ref self, fulfill_info);

            let order_hash = fulfill_info.order_hash;
            let order: OrderV1 = match order_read(order_hash) {
                Option::Some(o) => o,
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };
            let status = match order_status_read(order_hash) {
                Option::Some(s) => s,
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };
            assert(status == OrderStatus::Open, orderbook_errors::ORDER_NOT_FULFILLABLE);
            let order_type = match order_type_read(order_hash) {
                Option::Some(s) => s,
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };
            let (execution_info, related_order_hash) = match order_type {
                OrderType::Listing => self._fulfill_listing_order(fulfill_info, order),
                OrderType::Auction => self._fulfill_auction_order(fulfill_info, order),
                OrderType::Offer => self._fulfill_offer(fulfill_info, order),
                OrderType::CollectionOffer => self._fulfill_offer(fulfill_info, order),
                OrderType::LimitBuy => self._fulfill_limit_order(fulfill_info, order),
                OrderType::LimitSell => self._fulfill_limit_order(fulfill_info, order),
            };

            self
                .emit(
                    OrderFulfilled {
                        order_hash: fulfill_info.order_hash,
                        fulfiller: fulfill_info.fulfiller,
                        related_order_hash,
                        order_type,
                        version: ORDER_FULFILLED_EVENT_VERSION,
                    }
                );

            HooksFulfillOrder::after_fulfill_order(ref self, fulfill_info);
            execution_info
        }
    }

    // *************************************************************************
    // INTERNAL FUNCTIONS
    // *************************************************************************
    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        /// Fulfill auction order
        ///
        /// # Arguments
        /// * `fulfill_info` - The execution info of the order.
        /// * `order_type` - The type of the order.
        ///
        fn _fulfill_auction_order(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo, order: OrderV1
        ) -> (Option<ExecutionInfo>, Option<felt252>) {
            let block_timestamp = starknet::get_block_timestamp();
            assert(
                order.offerer == fulfill_info.fulfiller, orderbook_errors::ORDER_NOT_SAME_OFFERER
            );
            // get auction end date from storage
            let (_, end_date, _) = self.auctions.read(order.compute_token_hash());
            assert(
                end_date + AUCTION_ACCEPTING_TIME_SECS > block_timestamp,
                orderbook_errors::ORDER_EXPIRED
            );

            let related_order_hash = fulfill_info
                .related_order_hash
                .expect(orderbook_errors::ORDER_MISSING_RELATED_ORDER);

            match order_type_read(related_order_hash) {
                Option::Some(order_type) => {
                    assert(
                        order_type == OrderType::Offer || order_type == OrderType::CollectionOffer,
                        orderbook_errors::ORDER_NOT_AN_OFFER
                    );
                },
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            }

            match order_status_read(related_order_hash) {
                Option::Some(s) => {
                    assert(s == OrderStatus::Open, orderbook_errors::ORDER_NOT_OPEN);
                    s
                },
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };

            let related_order = match order_read::<OrderV1>(related_order_hash) {
                Option::Some(o) => o,
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };

            let related_offer_auction = self.auction_offers.read(related_order_hash);

            if related_offer_auction.is_non_zero() {
                assert(
                    related_offer_auction == fulfill_info.order_hash,
                    orderbook_errors::ORDER_HASH_DOES_NOT_MATCH
                );
            } else {
                assert(related_order.end_date > block_timestamp, orderbook_errors::ORDER_EXPIRED);
            }
            let related_order_token_hash = related_order.compute_token_hash();
            assert(
                related_order_token_hash == order.compute_token_hash(),
                orderbook_errors::ORDER_TOKEN_HASH_DOES_NOT_MATCH
            );
            assert(
                related_order.token_id == order.token_id,
                orderbook_errors::ORDER_TOKEN_ID_DOES_NOT_MATCH
            );

            order_status_write(related_order_hash, OrderStatus::Fulfilled);
            order_status_write(fulfill_info.order_hash, OrderStatus::Fulfilled);

            if order.token_id.is_some() {
                let execute_info = ExecutionInfo {
                    order_hash: order.compute_order_hash(),
                    token_address: order.token_address,
                    token_from: order.offerer,
                    token_to: related_order.offerer,
                    token_id: OptionU256 { is_some: 1, value: order.token_id.unwrap() },
                    token_quantity: order.quantity,
                    payment_from: related_order.offerer,
                    payment_to: fulfill_info.fulfiller,
                    payment_amount: related_order.start_amount,
                    payment_currency_address: related_order.currency_address,
                    payment_currency_chain_id: related_order.currency_chain_id,
                    listing_broker_address: order.broker_id,
                    fulfill_broker_address: fulfill_info.fulfill_broker_address
                };
                (Option::Some(execute_info), Option::Some(related_order_hash))
            } else {
                (Option::None, Option::Some(related_order_hash))
            }
        }

        /// Fulfill offer order
        ///
        /// # Arguments
        /// * `fulfill_info` - The execution info of the order.
        /// * `order` - The order.
        ///
        fn _fulfill_offer(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo, order: OrderV1
        ) -> (Option<ExecutionInfo>, Option<felt252>) {
            if order.token_id.is_some() {
                let (auction_order_hash, _, _) = self.auctions.read(order.compute_token_hash());

                assert(auction_order_hash.is_zero(), orderbook_errors::USE_FULFILL_AUCTION);
            }

            assert(fulfill_info.token_id.is_some(), orderbook_errors::ORDER_TOKEN_ID_IS_MISSING);

            let current_date = starknet::get_block_timestamp();
            assert(order.end_date > current_date, orderbook_errors::ORDER_EXPIRED);
            order_status_write(fulfill_info.order_hash, OrderStatus::Fulfilled);

            if order.token_id.is_some() {
                // remove token from listed tokens
                self.token_listings.write(order.compute_token_hash(), 0);
            }

            let execute_info = ExecutionInfo {
                order_hash: order.compute_order_hash(),
                token_address: order.token_address,
                token_from: fulfill_info.fulfiller,
                token_to: order.offerer,
                token_id: OptionU256 { is_some: 1, value: fulfill_info.token_id.unwrap() },
                token_quantity: order.quantity,
                payment_from: order.offerer,
                payment_to: fulfill_info.fulfiller,
                payment_amount: order.start_amount,
                payment_currency_address: order.currency_address,
                payment_currency_chain_id: order.currency_chain_id,
                listing_broker_address: order.broker_id,
                fulfill_broker_address: fulfill_info.fulfill_broker_address
            };
            (Option::Some(execute_info), Option::None)
        }

        /// Fulfill listing order
        ///
        /// # Arguments
        /// * `fulfill_info` - The execution info of the order.
        /// * `order_type` - The type of the order.
        ///
        fn _fulfill_listing_order(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo, order: OrderV1
        ) -> (Option<ExecutionInfo>, Option<felt252>) {
            assert(order.offerer != fulfill_info.fulfiller, orderbook_errors::ORDER_SAME_OFFERER);
            assert(
                order.end_date > starknet::get_block_timestamp(), orderbook_errors::ORDER_EXPIRED
            );
            order_status_write(fulfill_info.order_hash, OrderStatus::Fulfilled);

            if order.token_id.is_some() {
                let execute_info = ExecutionInfo {
                    order_hash: order.compute_order_hash(),
                    token_address: order.token_address,
                    token_from: order.offerer,
                    token_to: fulfill_info.fulfiller,
                    token_id: OptionU256 { is_some: 1, value: order.token_id.unwrap() },
                    token_quantity: order.quantity,
                    payment_from: fulfill_info.fulfiller,
                    payment_to: order.offerer,
                    payment_amount: order.start_amount,
                    payment_currency_address: order.currency_address,
                    payment_currency_chain_id: order.currency_chain_id,
                    listing_broker_address: order.broker_id,
                    fulfill_broker_address: fulfill_info.fulfill_broker_address
                };
                (Option::Some(execute_info), Option::None)
            } else {
                (Option::None, Option::None)
            }
        }

        /// Get order hash from token hash
        ///
        /// # Arguments
        /// * `token_hash` - The token hash of the order.
        ///
        fn _get_order_hash_from_token_hash(
            self: @ComponentState<TContractState>, token_hash: felt252
        ) -> felt252 {
            self.token_listings.read(token_hash)
        }

        /// get previous order
        ///
        /// # Arguments
        /// * `token_hash` - The token hash of the order.
        ///
        /// # Return option of (order hash: felt252, is_order_expired: bool, order: OrderV1)
        /// * order_hash
        /// * is_order_expired
        /// * order
        fn _get_previous_order(
            self: @ComponentState<TContractState>, token_hash: felt252
        ) -> Option<(felt252, bool, OrderV1)> {
            let previous_listing_orderhash = self.token_listings.read(token_hash);
            let (previous_auction_orderhash, _, _) = self.auctions.read(token_hash);
            let mut previous_orderhash = 0;
            if (previous_listing_orderhash.is_non_zero()) {
                previous_orderhash = previous_listing_orderhash;
                let previous_order: Option<OrderV1> = order_read(previous_orderhash);
                assert(previous_order.is_some(), 'Order must exist');
                let previous_order = previous_order.unwrap();
                return Option::Some(
                    (
                        previous_orderhash,
                        previous_order.end_date <= starknet::get_block_timestamp(),
                        previous_order
                    )
                );
            }
            if (previous_auction_orderhash.is_non_zero()) {
                previous_orderhash = previous_auction_orderhash;
                let current_order: Option<OrderV1> = order_read(previous_orderhash);
                assert(current_order.is_some(), 'Order must exist');
                let current_order = current_order.unwrap();
                let (_, auction_end_date, _) = self.auctions.read(token_hash);
                return Option::Some(
                    (
                        previous_orderhash,
                        auction_end_date <= starknet::get_block_timestamp(),
                        current_order
                    )
                );
            } else {
                return Option::None;
            }
        }

        /// Process previous order
        ///
        /// # Arguments
        /// * `token_hash` - The token hash of the order.
        ///
        fn _process_previous_order(
            ref self: ComponentState<TContractState>, token_hash: felt252, offerer: ContractAddress
        ) -> Option<felt252> {
            let previous_order = self._get_previous_order(token_hash);
            if (previous_order.is_some()) {
                let (previous_orderhash, previous_order_is_expired, previous_order) = previous_order
                    .unwrap();
                let previous_order_status = order_status_read(previous_orderhash)
                    .expect('Invalid Order status');
                assert(
                    previous_order_status != OrderStatus::Fulfilled,
                    orderbook_errors::ORDER_FULFILLED
                );
                if (previous_order.offerer == offerer) {
                    assert(previous_order_is_expired, orderbook_errors::ORDER_NOT_CANCELLABLE);
                }
                order_status_write(previous_orderhash, OrderStatus::CancelledByNewOrder);
                return Option::Some(previous_orderhash);
            }
            return Option::None;
        }

        /// Creates a listing order.
        fn _create_listing_order(
            ref self: ComponentState<TContractState>,
            order: OrderV1,
            order_type: OrderType,
            order_hash: felt252,
        ) -> Option<felt252> {
            let token_hash = order.compute_token_hash();
            // revert if order is fulfilled or Open
            let current_order_hash = self.token_listings.read(token_hash);
            if (current_order_hash.is_non_zero()) {
                assert(
                    order_status_read(current_order_hash) != Option::Some(OrderStatus::Fulfilled),
                    orderbook_errors::ORDER_FULFILLED
                );
            }
            let current_order: Option<OrderV1> = order_read(current_order_hash);
            if (current_order.is_some()) {
                let current_order = current_order.unwrap();
                // check if same offerer
                if (current_order.offerer == order.offerer) {
                    // check expiration if order is expired continue
                    assert(
                        current_order.end_date <= starknet::get_block_timestamp(),
                        orderbook_errors::ORDER_ALREADY_EXISTS
                    );
                }
            }

            let cancelled_order_hash = self._process_previous_order(token_hash, order.offerer);
            order_write(order_hash, order_type, order);
            self.token_listings.write(token_hash, order_hash);
            self
                .emit(
                    OrderPlaced {
                        order_hash: order_hash,
                        order_version: order.get_version(),
                        order_type: order_type,
                        version: ORDER_PLACED_EVENT_VERSION,
                        cancelled_order_hash,
                        order: order
                    }
                );
            cancelled_order_hash
        }

        /// Creates an auction order.
        fn _create_auction(
            ref self: ComponentState<TContractState>,
            order: OrderV1,
            order_type: OrderType,
            order_hash: felt252
        ) {
            let token_hash = order.compute_token_hash();
            let current_order_hash = self.token_listings.read(token_hash);
            if (current_order_hash.is_non_zero()) {
                assert(
                    order_status_read(current_order_hash) != Option::Some(OrderStatus::Fulfilled),
                    orderbook_errors::ORDER_FULFILLED
                );
            }
            let current_order: Option<OrderV1> = order_read(current_order_hash);
            if (current_order.is_some()) {
                let current_order = current_order.unwrap();
                // check expiration if order is expired continue
                if (current_order.offerer == order.offerer) {
                    assert(
                        current_order.end_date <= starknet::get_block_timestamp(),
                        orderbook_errors::ORDER_ALREADY_EXISTS
                    );
                }
            }
            let token_hash = order.compute_token_hash();
            let cancelled_order_hash = self._process_previous_order(token_hash, order.offerer);
            order_write(order_hash, order_type, order);
            self.auctions.write(token_hash, (order_hash, order.end_date, 0));
            self
                .emit(
                    OrderPlaced {
                        order_hash: order_hash,
                        order_version: order.get_version(),
                        order_type: order_type,
                        version: ORDER_PLACED_EVENT_VERSION,
                        cancelled_order_hash,
                        order: order,
                    }
                );
        }

        fn _manage_auction_offer(
            ref self: ComponentState<TContractState>, order: OrderV1, order_hash: felt252
        ) {
            let token_hash = order.compute_token_hash();
            let (auction_order_hash, auction_end_date, auction_offer_count) = self
                .auctions
                .read(token_hash);

            let current_block_timestamp = starknet::get_block_timestamp();
            // Determine if the auction end date has passed, indicating that the auction is still
            // ongoing.
            let auction_is_pending = current_block_timestamp < auction_end_date;

            if auction_is_pending {
                // If the auction is still pending, record the new offer by linking it to the
                // auction order hash in the 'auction_offers' mapping.
                self.auction_offers.write(order_hash, auction_order_hash);

                if auction_end_date - current_block_timestamp < EXTENSION_TIME_IN_SECONDS {
                    // Increment the number of offers for this auction and extend the auction
                    // end date by the predefined extension time to allow for additional offers.
                    self
                        .auctions
                        .write(
                            token_hash,
                            (
                                auction_order_hash,
                                auction_end_date + EXTENSION_TIME_IN_SECONDS,
                                auction_offer_count + 1
                            )
                        );
                } else {
                    self
                        .auctions
                        .write(
                            token_hash,
                            (auction_order_hash, auction_end_date, auction_offer_count + 1)
                        );
                }
            }
        }

        /// Creates an offer order.
        fn _create_offer(
            ref self: ComponentState<TContractState>,
            order: OrderV1,
            order_type: OrderType,
            order_hash: felt252
        ) {
            self._manage_auction_offer(order, order_hash);
            order_write(order_hash, order_type, order);
            self
                .emit(
                    OrderPlaced {
                        order_hash: order_hash,
                        order_version: order.get_version(),
                        order_type: order_type,
                        version: ORDER_PLACED_EVENT_VERSION,
                        cancelled_order_hash: Option::None,
                        order: order,
                    }
                );
        }

        /// Creates a collection offer order.
        fn _create_collection_offer(
            ref self: ComponentState<TContractState>,
            order: OrderV1,
            order_type: OrderType,
            order_hash: felt252
        ) {
            order_write(order_hash, order_type, order);
            self
                .emit(
                    OrderPlaced {
                        order_hash: order_hash,
                        order_version: order.get_version(),
                        order_type,
                        version: ORDER_PLACED_EVENT_VERSION,
                        cancelled_order_hash: Option::None,
                        order: order,
                    }
                );
        }

        /// Creates a limit buy order
        fn _create_limit_order(
            ref self: ComponentState<TContractState>,
            order: OrderV1,
            order_type: OrderType,
            order_hash: felt252
        ) {
            // revert if order is fulfilled or Open
            let (price, _) = self.buy_orders.read(order_hash);
            if (price.is_non_zero()) {
                assert(
                    order_status_read(order_hash) != Option::Some(OrderStatus::Fulfilled),
                    panic_with_felt252(orderbook_errors::ORDER_FULFILLED)
                );
            }
            let cancelled_order_hash = self._process_previous_order(order_hash, order.offerer);

            order_write(order_hash, order_type, order);

            match order_type {
                OrderType::LimitBuy => {
                    let price = order.start_amount / order.quantity * PRECISION;
                    self.buy_orders.write(order_hash, (price, order.quantity));
                },
                OrderType::LimitSell => {
                    let price = order.end_amount / order.quantity * PRECISION;
                    self.sell_orders.write(order_hash, (price, order.quantity));
                },
                _ => ()
            }

            self
                .emit(
                    OrderPlaced {
                        order_hash: order_hash,
                        order_version: order.get_version(),
                        order_type: order_type,
                        version: ORDER_PLACED_EVENT_VERSION,
                        cancelled_order_hash,
                        order: order
                    }
                );
        }

        fn _create_listing_execution_info(
            ref self: ComponentState<TContractState>,
            order_hash: felt252,
            buy_order: OrderV1,
            sell_order: OrderV1,
            fulfill_info: FulfillInfo,
            token_quantity: u256,
            listing_broker_address: ContractAddress,
            price: u256
        ) -> ExecutionInfo {
            ExecutionInfo {
                order_hash,
                token_address: buy_order.token_address,
                token_from: sell_order.offerer,
                token_to: buy_order.offerer,
                token_id: OptionU256 { is_some: 0, value: 0 },
                token_quantity,
                payment_from: buy_order.offerer,
                payment_to: sell_order.offerer,
                payment_amount: price * token_quantity / PRECISION,
                payment_currency_address: buy_order.currency_address,
                payment_currency_chain_id: buy_order.currency_chain_id,
                listing_broker_address: listing_broker_address,
                fulfill_broker_address: fulfill_info.fulfill_broker_address,
            }
        }

        /// Fulfill limit order
        fn _fulfill_limit_order(
            ref self: ComponentState<TContractState>, fulfill_info: FulfillInfo, order: OrderV1
        ) -> (Option<ExecutionInfo>, Option<felt252>) {
            let order_hash = order.compute_order_hash();

            assert(
                order_hash == fulfill_info.order_hash, orderbook_errors::ORDER_HASH_DOES_NOT_MATCH
            );

            let related_order_hash = fulfill_info
                .related_order_hash
                .expect(orderbook_errors::ORDER_MISSING_RELATED_ORDER);

            match order_type_read(related_order_hash) {
                Option::Some(order_type) => {
                    assert(
                        order_type == OrderType::LimitBuy || order_type == OrderType::LimitSell,
                        orderbook_errors::ORDER_NOT_AN_ERC20_ORDER
                    );
                },
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            }

            match order_status_read(related_order_hash) {
                Option::Some(s) => {
                    assert(s == OrderStatus::Open, orderbook_errors::ORDER_NOT_OPEN);
                    s
                },
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };

            let related_order = match order_read::<OrderV1>(related_order_hash) {
                Option::Some(o) => o,
                Option::None => panic_with_felt252(orderbook_errors::ORDER_NOT_FOUND),
            };

            let related_order_token_hash = related_order.compute_token_hash();

            // check that they are both the same token
            assert(
                related_order_token_hash == order.compute_token_hash(),
                orderbook_errors::ORDER_TOKEN_HASH_DOES_NOT_MATCH
            );

            let (buy_order, sell_order) = match order.route {
                RouteType::Erc20ToErc20Sell => {
                    assert(
                        related_order.route == RouteType::Erc20ToErc20Buy,
                        orderbook_errors::ORDER_ROUTE_NOT_VALID
                    );
                    (related_order, order)
                },
                RouteType::Erc20ToErc20Buy => {
                    assert(
                        related_order.route == RouteType::Erc20ToErc20Sell,
                        orderbook_errors::ORDER_ROUTE_NOT_VALID
                    );
                    (order, related_order)
                },
                _ => panic!("route not supported")
            };

            // add 1e18 to the multiplication;

            // check that the price is the same
            let buy_price = buy_order.start_amount / buy_order.quantity * PRECISION;
            let sell_price = sell_order.end_amount / sell_order.quantity * PRECISION;

            let buy_order_hash = buy_order.compute_order_hash();
            let sell_order_hash = sell_order.compute_order_hash();

            assert(buy_price == sell_price, orderbook_errors::ORDER_PRICE_NOT_MATCH);

            let (_, buy_order_quantity) = self.buy_orders.read(buy_order_hash);
            let (_, sell_order_quantity) = self.sell_orders.read(sell_order_hash);

            if buy_order_quantity > sell_order_quantity {
                // reduce buy quantity order and execute sell order
                self
                    .buy_orders
                    .write(buy_order_hash, (buy_price, buy_order_quantity - sell_order_quantity));
                // set buy order as fufilled
                order_status_write(sell_order_hash, OrderStatus::Fulfilled);
                // set execute info
                let execute_info = self
                    ._create_listing_execution_info(
                        sell_order_hash,
                        buy_order,
                        sell_order,
                        fulfill_info,
                        sell_order_quantity,
                        related_order.broker_id,
                        buy_price
                    );
                (Option::Some(execute_info), Option::Some(related_order_hash))
            } else if sell_order_quantity > buy_order_quantity {
                // reduce sell quantity, and execute buy order
                self
                    .sell_orders
                    .write(sell_order_hash, (sell_price, sell_order_quantity - buy_order_quantity));
                // set sell order as fulfilled
                order_status_write(buy_order_hash, OrderStatus::Fulfilled);
                // generate execution info
                let execute_info = self
                    ._create_listing_execution_info(
                        buy_order_hash,
                        buy_order,
                        sell_order,
                        fulfill_info,
                        buy_order_quantity,
                        order.broker_id,
                        buy_price
                    );
                (Option::Some(execute_info), Option::Some(related_order_hash))
            } else {
                // execute both orders
                order_status_write(buy_order_hash, OrderStatus::Fulfilled);
                order_status_write(sell_order_hash, OrderStatus::Fulfilled);
                // passing any of them as the order hash will fulfill both orders,
                // so just one executioninfo will be sent.
                let execute_info = self
                    ._create_listing_execution_info(
                        buy_order_hash,
                        buy_order,
                        sell_order,
                        fulfill_info,
                        buy_order_quantity,
                        order.broker_id,
                        buy_price
                    );
                // return
                (Option::Some(execute_info), Option::Some(related_order_hash))
            }
        }
    }
}
pub impl OrderbookHooksCreateOrderEmptyImpl<
    TContractState
> of OrderbookComponent::OrderbookHooksCreateOrderTrait<TContractState> {}
pub impl OrderbookHooksCancelOrderEmptyImpl<
    TContractState
> of OrderbookComponent::OrderbookHooksCancelOrderTrait<TContractState> {}
pub impl OrderbookHooksFulfillOrderEmptyImpl<
    TContractState
> of OrderbookComponent::OrderbookHooksFulfillOrderTrait<TContractState> {}
pub impl OrderbookHooksValidateOrderExecutionEmptyImpl<
    TContractState
> of OrderbookComponent::OrderbookHooksValidateOrderExecutionTrait<TContractState> {}
