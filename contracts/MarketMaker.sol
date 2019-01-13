pragma solidity ^0.5.1;
import "erc-1155/contracts/IERC1155TokenReceiver.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "@gnosis.pm/util-contracts/contracts/SignedSafeMath.sol";
import "@gnosis.pm/hg-contracts/contracts/PredictionMarketSystem.sol";

contract MarketMaker is Ownable, IERC1155TokenReceiver {
    using SignedSafeMath for int;
    using SafeMath for uint;
    /*
     *  Constants
     */    
    uint64 public constant FEE_RANGE = 10**18;

    /*
     *  Events
     */
    event AMMCreated(uint initialFunding);
    event AMMPaused();
    event AMMResumed();
    event AMMClosed();
    event AMMFundingChanged(int fundingChange);
    event AMMFeeChanged(uint64 newFee);
    event AMMFeeWithdrawal(uint fees);
    event AMMOutcomeTokenTrade(address indexed transactor, int[] outcomeTokenAmounts, int outcomeTokenNetCost, uint marketFees);
    
    /*
     *  Storage
     */
    PredictionMarketSystem public pmSystem;
    IERC20 public collateralToken;
    bytes32 public conditionId;

    uint64 public fee;
    uint public funding;
    Stage public stage;
    enum Stage {
        Running,
        Paused,
        Closed
    }

    /*
     *  Modifiers
     */
    modifier atStage(Stage _stage) {
        // Contract has to be in given stage
        require(stage == _stage);
        _;
    }

    constructor(PredictionMarketSystem _pmSystem, IERC20 _collateralToken, bytes32 _conditionId, uint64 _fee, uint initialFunding, address marketOwner)
        public
    {
        // Validate inputs
        require(address(_pmSystem) != address(0) && _fee < FEE_RANGE);
        pmSystem = _pmSystem;
        collateralToken = _collateralToken;
        conditionId = _conditionId;
        fee = _fee;

        require(collateralToken.transferFrom(marketOwner, address(this), initialFunding) && collateralToken.approve(address(pmSystem), initialFunding));
        uint[] memory partition = generateBasicPartition();
        pmSystem.splitPosition(collateralToken, bytes32(0), conditionId, partition, initialFunding);
        funding = initialFunding;

        stage = Stage.Running;
        emit AMMCreated(funding);
    }

    function calcNetCost(int[] memory outcomeTokenAmounts) public view returns (int netCost);

    /// @dev Allows to fund the market with collateral tokens converting them into outcome tokens
    /// Note for the future: should combine splitPosition and mergePositions into one function, as code duplication causes things like this to happen.
    function changeFunding(int fundingChange)
        public
        onlyOwner
        atStage(Stage.Paused)
    {
        require(fundingChange != 0, "A fundingChange of zero is not a fundingChange at all. It is unacceptable.");
        // Either add or subtract funding based off whether the fundingChange parameter is negative or positive
        if (fundingChange > 0) {
            require(collateralToken.transferFrom(msg.sender, address(this), uint(fundingChange)) && collateralToken.approve(address(pmSystem), uint(fundingChange)));
            uint[] memory addFundingPartition = generateBasicPartition();
            pmSystem.splitPosition(collateralToken, bytes32(0), conditionId, addFundingPartition, uint(fundingChange));
            funding = funding.add(uint(fundingChange));
            emit AMMFundingChanged(fundingChange);
        }
        if (fundingChange < 0) {
            uint[] memory removeFundingPartition = generateBasicPartition();
            pmSystem.mergePositions(collateralToken, bytes32(0), conditionId, removeFundingPartition, uint(-fundingChange));
            funding = funding.sub(uint(-fundingChange));
            require(collateralToken.transfer(owner(), uint(-fundingChange)));
            emit AMMFundingChanged(fundingChange);
        }
    }

    function pause() public onlyOwner atStage(Stage.Running) {
        stage = Stage.Paused;
        emit AMMPaused();
    }
    
    function resume() public onlyOwner atStage(Stage.Paused) {
        stage = Stage.Running;
        emit AMMResumed();
    }

    function changeFee(uint64 _fee) public onlyOwner atStage(Stage.Paused) {
        fee = _fee;
        emit AMMFeeChanged(fee);
    }

    /// @dev Allows market owner to close the markets by transferring all remaining outcome tokens to the owner
    function close()
        public
        onlyOwner
    {
        require(stage == Stage.Running || stage == Stage.Paused, "This Market has already been closed");
        uint outcomeSlotCount = pmSystem.getOutcomeSlotCount(conditionId);
        for (uint i = 0; i < outcomeSlotCount; i++) {
            uint positionId = generateBasicPositionId(i);
            pmSystem.safeTransferFrom(address(this), owner(), positionId, pmSystem.balanceOf(address(this), positionId), "");
        }
        stage = Stage.Closed;
        emit AMMClosed();
    }

    /// @dev Allows market owner to withdraw fees generated by trades
    /// @return Fee amount
    function withdrawFees()
        public
        onlyOwner
        returns (uint fees)
    {
        fees = collateralToken.balanceOf(address(this));
        // Transfer fees
        require(collateralToken.transfer(owner(), fees));
        emit AMMFeeWithdrawal(fees);
    }

    /// @dev Allows to trade outcome tokens and collateral with the market maker
    /// @param outcomeTokenAmounts Amounts of each outcome token to buy or sell. If positive, will buy this amount of outcome token from the market. If negative, will sell this amount back to the market instead.
    /// @param collateralLimit If positive, this is the limit for the amount of collateral tokens which will be sent to the market to conduct the trade. If negative, this is the minimum amount of collateral tokens which will be received from the market for the trade. If zero, there is no limit.
    /// @return If positive, the amount of collateral sent to the market. If negative, the amount of collateral received from the market. If zero, no collateral was sent or received.
    function trade(int[] memory outcomeTokenAmounts, int collateralLimit)
        public
        atStage(Stage.Running)
        returns (int netCost)
    {
        uint outcomeSlotCount = pmSystem.getOutcomeSlotCount(conditionId);
        require(outcomeTokenAmounts.length == outcomeSlotCount);
        uint[] memory partition = generateBasicPartition();

        // Calculate net cost for executing trade
        int outcomeTokenNetCost = calcNetCost(outcomeTokenAmounts);
        int fees;
        if(outcomeTokenNetCost < 0)
            fees = int(calcMarketFee(uint(-outcomeTokenNetCost)));
        else
            fees = int(calcMarketFee(uint(outcomeTokenNetCost)));

        require(fees >= 0);
        netCost = outcomeTokenNetCost.add(fees);

        require(
            (collateralLimit != 0 && netCost <= collateralLimit) ||
            collateralLimit == 0
        );

        if(outcomeTokenNetCost > 0) {
            require(
                collateralToken.transferFrom(msg.sender, address(this), uint(netCost)) &&
                collateralToken.approve(address(pmSystem), uint(outcomeTokenNetCost))
            );

            pmSystem.splitPosition(collateralToken, bytes32(0), conditionId, partition, uint(outcomeTokenNetCost));
        }

        for (uint i = 0; i < outcomeSlotCount; i++) {
            if(outcomeTokenAmounts[i] != 0) {
                uint positionId = generateBasicPositionId(i);
                if(outcomeTokenAmounts[i] < 0) {
                    pmSystem.safeTransferFrom(msg.sender, address(this), positionId, uint(-outcomeTokenAmounts[i]), "");
                } else {
                    pmSystem.safeTransferFrom(address(this), msg.sender, positionId, uint(outcomeTokenAmounts[i]), "");
                }

            }
        }

        if(outcomeTokenNetCost < 0) {
            // This is safe since
            // 0x8000000000000000000000000000000000000000000000000000000000000000 ==
            // uint(-int(-0x8000000000000000000000000000000000000000000000000000000000000000))
            pmSystem.mergePositions(collateralToken, bytes32(0), conditionId, partition, uint(-outcomeTokenNetCost));
            if(netCost < 0) {
                require(collateralToken.transfer(msg.sender, uint(-netCost)));
            }
        }

        emit AMMOutcomeTokenTrade(msg.sender, outcomeTokenAmounts, outcomeTokenNetCost, uint(fees));
    }

    /// @dev Calculates fee to be paid to market maker
    /// @param outcomeTokenCost Cost for buying outcome tokens
    /// @return Fee for trade
    function calcMarketFee(uint outcomeTokenCost)
        public
        view
        returns (uint)
    {
        return outcomeTokenCost * fee / FEE_RANGE;
    }

    function onERC1155Received(address operator, address /*from*/, uint256 /*id*/, uint256 /*value*/, bytes calldata /*data*/) external returns(bytes4) {
        if (operator == address(this)) {
            return 0xf23a6e61;
        }
        return 0x0;
    }

    function onERC1155BatchReceived(address _operator, address /*from*/, uint256[] calldata /*ids*/, uint256[] calldata /*values*/, bytes calldata /*data*/) external view returns(bytes4) {
        if (_operator == address(this)) {
            return 0xf23a6e61;
        }
        return 0x0;
    }

    function generateBasicPartition()
        private
        view
        returns (uint[] memory partition)
    {
        partition = new uint[](pmSystem.getOutcomeSlotCount(conditionId));
        for(uint i = 0; i < partition.length; i++) {
            partition[i] = 1 << i;
        }
    }

    function generateBasicPositionId(uint i)
        internal
        view
        returns (uint)
    {
        return uint(keccak256(abi.encodePacked(
            collateralToken,
            keccak256(abi.encodePacked(
                conditionId,
                1 << i)))));
    }
}