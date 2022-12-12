// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Clock auction for non-fungible tokens.
contract NftMarketplace is Pausable {
    using SafeERC20 for IERC20;
    // Represents an auction on an NFT
    struct Auction {
        // Current owner of NFT
        address seller;
        // Price at beginning of auction
        uint128 startingPrice;
        address token;
        // Duration (in seconds) of auction
        uint64 duration;
        // Time when auction started
        // NOTE: 0 if this auction has been concluded
        uint64 startedAt;
        address highestBidder;
        uint256 highestPrice;
        bool ended;
    }

    struct Listing {
        uint256 price;
        bool listed;
        address seller;
        address token;
    }

    // Cut owner takes on each auction, measured in basis points (1/100 of a percent).
    // Values 0-10,000 map to 0%-100%
    uint256 public ownerCut;

    // Map from token ID to their corresponding auction.
    mapping(address => mapping(uint256 => Auction)) public auctions;

    // Map from token ID to listing price
    mapping(address => mapping(uint256 => Listing)) public listing;

    event AuctionCreated(
        address indexed _nftAddress,
        uint256 indexed _tokenId,
        uint256 _startingPrice,
        address _token,
        uint256 _duration,
        address _seller
    );

    event ListingCreated(
        address indexed _nftAddress,
        uint256 indexed _tokenId,
        uint256 _price,
        address _seller,
        address _token
    );

    event BuySucceed(
        address indexed _nftAddress,
        uint256 indexed _tokenId,
        uint256 _price
    );

    event SetPrice(
        address indexed _nftAddress,
        uint256 indexed _tokenId,
        uint256 _price
    );

    event AuctionCancelled(
        address indexed _nftAddress,
        uint256 indexed _tokenId
    );

    /// @dev Constructor creates a reference to the NFT ownership contract
    ///  and verifies the owner cut is in the valid range.
    /// @param _ownerCut - percent cut the owner takes on each auction, must be
    ///  between 0-10,000.
    constructor(uint256 _ownerCut) {
        require(_ownerCut <= 10000);
        ownerCut = _ownerCut;
    }

    /// @dev DON'T give me your money.
    //   function () external {}

    // Modifiers to check that inputs can be safely stored with a certain
    // number of bits. We use constants and multiple modifiers to save gas.
    modifier canBeStoredWith64Bits(uint256 _value) {
        require(_value <= 18446744073709551615);
        _;
    }

    modifier canBeStoredWith128Bits(uint256 _value) {
        require(_value < 340282366920938463463374607431768211455);
        _;
    }

    /// @dev Returns auction info for an NFT on auction.
    /// @param _nftAddress - Address of the NFT.
    /// @param _tokenId - ID of NFT on auction.
    function getAuction(address _nftAddress, uint256 _tokenId)
        external
        view
        returns (
            address seller,
            uint256 startingPrice,
            uint256 duration,
            uint256 startedAt
        )
    {
        Auction storage _auction = auctions[_nftAddress][_tokenId];
        require(_isOnAuction(_auction));
        return (
            _auction.seller,
            _auction.startingPrice,
            _auction.duration,
            _auction.startedAt
        );
    }

    /// @dev Returns the highest price of an auction.
    /// @param _nftAddress - Address of the NFT.
    /// @param _tokenId - ID of the token price we are checking.
    function getHighestPrice(address _nftAddress, uint256 _tokenId)
        external
        view
        returns (uint256)
    {
        Auction storage _auction = auctions[_nftAddress][_tokenId];
        require(_isOnAuction(_auction));
        return _auction.highestPrice;
    }

    /// @dev Creates and begins a new auction.
    /// @param _nftAddress - address of a deployed contract implementing
    ///  the Nonfungible Interface.
    /// @param _tokenId - ID of token to auction, sender must be owner.
    /// @param _startingPrice - Price of item (in wei) at beginning of auction.
    /// @param _duration - Length of time to move between starting
    ///  price and ending price (in seconds).
    function createAuction(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _startingPrice,
        uint256 _duration,
        address _token
    )
        external
        whenNotPaused
        canBeStoredWith128Bits(_startingPrice)
        canBeStoredWith64Bits(_duration)
    {
        address _seller = msg.sender;
        require(listing[_nftAddress][_tokenId].listed == false, "listing nft");
        require(_owns(_nftAddress, _seller, _tokenId), "Not own nft");
        _approve(_nftAddress, _tokenId);
        Auction memory _auction = Auction(
            _seller,
            uint128(_startingPrice),
            _token,
            uint64(_duration),
            uint64(block.timestamp),
            address(0),
            _startingPrice,
            false
        );
        _addAuction(_nftAddress, _tokenId, _auction, _seller, _token);
    }

    /// @dev Bids on an open auction, completing the auction and transferring
    ///  ownership of the NFT if enough Ether is supplied.
    /// @param _nftAddress - address of a deployed contract implementing
    ///  the Nonfungible Interface.
    /// @param _tokenId - ID of token to bid on.
    function bid(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _price
    ) external payable whenNotPaused {
        Auction storage _auction = auctions[_nftAddress][_tokenId];
        require(_isOnAuction(_auction), "Auction not on");
        require(_price > _auction.highestPrice, "Invalid price");
        _auction.highestPrice = _price;
        _auction.highestBidder = msg.sender;
    }

    /// @dev Cancels an auction that hasn't been won yet.
    ///  Returns the NFT to original owner.
    /// @notice This is a state-modifying function that can
    ///  be called while the contract is paused.
    /// @param _nftAddress - Address of the NFT.
    /// @param _tokenId - ID of token on auction
    function cancelAuction(address _nftAddress, uint256 _tokenId) external {
        Auction memory _auction = auctions[_nftAddress][_tokenId];
        require(_isOnAuction(_auction), "Auction not on");
        require(msg.sender == _auction.seller, "Not authorized");
        _cancelAuction(_nftAddress, _tokenId);
    }

    /// @dev Returns true if the NFT is on auction.
    /// @param _auction - Auction to check.
    function _isOnAuction(Auction memory _auction)
        internal
        view
        returns (bool)
    {
        return (block.timestamp - _auction.startedAt < _auction.duration);
    }

    /// @dev Gets the NFT object from an address, validating that implementsERC721 is true.
    /// @param _nftAddress - Address of the NFT.
    function _getNftContract(address _nftAddress)
        internal
        pure
        returns (IERC721)
    {
        IERC721 candidateContract = IERC721(_nftAddress);
        // require(candidateContract.implementsERC721());
        return candidateContract;
    }

    /// @dev Returns true if the claimant owns the token.
    /// @param _nftAddress - The address of the NFT.
    /// @param _claimant - Address claiming to own the token.
    /// @param _tokenId - ID of token whose ownership to verify.
    function _owns(
        address _nftAddress,
        address _claimant,
        uint256 _tokenId
    ) internal view returns (bool) {
        IERC721 _nftContract = _getNftContract(_nftAddress);
        return (_nftContract.ownerOf(_tokenId) == _claimant);
    }

    /// @dev Adds an auction to the list of open auctions. Also fires the
    ///  AuctionCreated event.
    /// @param _tokenId The ID of the token to be put on auction.
    /// @param _auction Auction to add.
    function _addAuction(
        address _nftAddress,
        uint256 _tokenId,
        Auction memory _auction,
        address _seller,
        address _token
    ) internal {
        // Require that all auctions have a duration of
        // at least one minute. (Keeps our math from getting hairy!)
        require(_auction.duration >= 1 minutes, "Too short!");

        auctions[_nftAddress][_tokenId] = _auction;

        emit AuctionCreated(
            _nftAddress,
            _tokenId,
            uint256(_auction.startingPrice),
            _token,
            uint256(_auction.duration),
            _seller
        );
    }

    /// @dev Adds an listing to the list of open listings. Also fires the
    ///  ListingCreated event.
    /// @param _tokenId The ID of the token to be put on auction.
    /// @param _listing Auction to add.
    function _addListing(
        address _nftAddress,
        uint256 _tokenId,
        Listing memory _listing,
        address _seller,
        address _token
    ) internal {
        listing[_nftAddress][_tokenId] = _listing;

        emit ListingCreated(
            _nftAddress,
            _tokenId,
            uint256(_listing.price),
            _seller,
            _token
        );
    }

    /// @dev Removes an auction from the list of open auctions.
    /// @param _tokenId - ID of NFT on auction.
    function _removeAuction(address _nftAddress, uint256 _tokenId) internal {
        delete auctions[_nftAddress][_tokenId];
    }

    /// @dev Cancels an auction unconditionally.
    function _cancelAuction(address _nftAddress, uint256 _tokenId) internal {
        _removeAuction(_nftAddress, _tokenId);
        emit AuctionCancelled(_nftAddress, _tokenId);
    }

    /// @dev Approve to transfer nft when win auction
    /// @param _nftAddress - The address of the NFT.
    /// @param _tokenId - ID of token whose approval to verify.
    function _approve(
        address _nftAddress,
        uint256 _tokenId
    ) internal {
        IERC721 _nftContract = _getNftContract(_nftAddress);
        _nftContract.approve(address(this), _tokenId);
    }

    // win auction
    function perchase_nft(address _nftAddress, uint256 _tokenId) public {
        address _buyer = msg.sender;
        IERC721 _nftContract = _getNftContract(_nftAddress);
        Auction memory _auction = auctions[_nftAddress][_tokenId];
        require(!_isOnAuction(_auction), "auction is on");
        address _seller = _auction.seller;
        _nftContract.transferFrom(_seller, _buyer, _tokenId);

        IERC20(_auction.token).approve(address(this), _auction.highestPrice);
        IERC20(_auction.token).safeTransferFrom(
            _buyer,
            _seller,
            _auction.highestPrice
        );

        emit BuySucceed(_nftAddress, _tokenId, _auction.highestPrice);
    }

    // BUY FIXED PRICE

    function list_nft(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _price,
        address _token
    ) public {
        address _seller = msg.sender;
        require(_owns(_nftAddress, _seller, _tokenId), "Not own nft");
        _approve(_nftAddress, _tokenId);
        Listing memory _listing = Listing(
            uint128(_price),
            false,
            _seller,
            _token
        );
        _addListing(_nftAddress, _tokenId, _listing, _seller, _token);
    }

    function set_price(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _price
    ) public {
        address _seller = msg.sender;
        require(listing[_nftAddress][_tokenId].seller == _seller, "not seller");
        require(listing[_nftAddress][_tokenId].price > _price);
        listing[_nftAddress][_tokenId].price = _price;

        emit SetPrice(_nftAddress, _tokenId, _price);
    }

    function buy_nft(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _price
    ) public {
        address _buyer = msg.sender;
        IERC721 _nftContract = _getNftContract(_nftAddress);
        Listing memory _listing = listing[_nftAddress][_tokenId];
        require(_price >= _listing.price);
        address _seller = _listing.seller;
        _nftContract.transferFrom(_seller, _buyer, _tokenId);

        IERC20(_listing.token).approve(address(this), _price);
        IERC20(_listing.token).safeTransferFrom(_buyer, _seller, _price);

        emit BuySucceed(_nftAddress, _tokenId, _price);
    }
}