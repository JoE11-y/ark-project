import { describe, expect, it } from "vitest";

import { config, getAccounts, mintERC721 } from "@ark-project/test";

import { cancelOrder, createAuction } from "../src/actions/order/index.js";
import { getOrderStatus } from "../src/actions/read/index.js";

describe("cancelAuction", () => {
  it("default", async () => {
    const { seller, listingBroker } = getAccounts();
    const { tokenId, tokenAddress } = await mintERC721({ account: seller });

    const { orderHash } = await createAuction(config, {
      account: seller,
      brokerAddress: listingBroker.address,
      tokenAddress,
      tokenId,
      startAmount: BigInt(1)
    });

    await cancelOrder(config, {
      account: seller,
      orderHash: orderHash,
      tokenAddress,
      tokenId
    });

    const { orderStatus } = await getOrderStatus(config, { orderHash });

    expect(orderStatus).toBe("CancelledUser");
  }, 50_000);
});
