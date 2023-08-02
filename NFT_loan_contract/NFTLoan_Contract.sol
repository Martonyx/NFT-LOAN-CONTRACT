// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IERC721 {
    function safeTransferFrom(address _from, address _to, uint _nftId) external;
    function ownerOf(uint _nftId) external view returns (address);
}

contract NFTLoanContract is IERC721Receiver{
    address payable public owner;
    uint256 public loanDurationInDays = 30 days;
    uint256 public inReview = 7 days;

    enum LoanStatus { isOpen, inReview, isApproved, isPaid, isClosed }

    struct Loan {
        string loanTitle;
        string NFTDetails;
        string collateral;
        IERC721 nft;
        uint256 nftId;
        uint256 loanDuration;
        uint256 interestRate;
        uint256 loanAmount;
        address payable borrower;
        uint256 approvedAt;
        uint256 requestedAt;
        LoanStatus status;
    }

    mapping(uint256 => Loan) public loans;
    uint256 public loanCounter;
    uint256 private constant MAX_LOAN_LIMIT = 100; 

    constructor() {
        owner = payable(msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Authorized");
        _;
    }

    modifier loanExists(uint256 loanId) {
        require(loans[loanId].status != LoanStatus.isClosed, "Loan does not exist or has been closed");
        _;
    }

    function createNFTLoan(
        string memory _loanTitle,
        string memory _NFTDetails,
        string memory _collateral,
        address _nft,
        uint256 _interestRate
    ) public onlyOwner {
        require(loanCounter < MAX_LOAN_LIMIT, "Loan limit reached");
        
        loans[loanCounter] = Loan(
            _loanTitle,
            _NFTDetails,
            _collateral,
            IERC721(_nft),
            0,
            loanDurationInDays,
            _interestRate,
            0,
            payable(owner),
            0,
            0,
            LoanStatus.isOpen
        );

        loanCounter++;
    }

    function requestLoan(uint256 _loanId, address _nft, uint256 _nftId, uint256 _amount) public loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(keccak256(abi.encodePacked(loan.nft)) == keccak256(abi.encodePacked(_nft)), "collateral not met");
        require(loan.borrower == owner && loan.borrower != msg.sender, "Loan already approved or not available");
        require(loan.nft.ownerOf(_nftId) == msg.sender, "Only owned NFTs can be loaned");
        loan.loanAmount = _amount * 1 ether;
        loan.borrower = payable(msg.sender);
        loan.status = LoanStatus.inReview;
        loan.nftId = _nftId;
        loan.requestedAt = block.timestamp;
        loan.nft.safeTransferFrom(msg.sender, address(this), _nftId);

         // Check if the loan request is within the inReview duration
        if (block.timestamp >= loan.requestedAt + inReview && loan.status == LoanStatus.inReview) {
            // If the loan request is not approved within the loan duration,
            // transfer the collateral back to the borrower

            loan.nft.safeTransferFrom(address(this), loan.borrower, loan.nftId);
            loan.borrower = owner;
            loan.status = LoanStatus.isOpen;
            loan.loanAmount = 0;
            loan.nftId = 0;
            loan.requestedAt = 0;
        }
    }

    function onERC721Received(address /* operator */, address /* from */, uint256 /* tokenId */, bytes calldata /* data */) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function reclaimCollateral(uint256 _loanId) public loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.inReview, "Loan is not under review");
        require(msg.sender == loan.borrower, "Only the borrower can reclaim collateral");
        uint256 _nftId = loan.nftId;

        // Transfer the collateral amount back to the borrower
        loan.nft.safeTransferFrom(address(this), loan.borrower, _nftId);
        loan.status = LoanStatus.isOpen;
        loan.borrower = owner;
        loan.loanAmount = 0;
        loan.nftId = 0;
        loan.requestedAt = 0;
    }

    function approveLoan(uint256 _loanId) public payable onlyOwner loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.inReview, "Loan is not under review");
        require(msg.value >= loan.loanAmount, "Collateral not met");

        (bool success, ) = payable(loan.borrower).call{value: loan.loanAmount}("");
        require(success, "Transfer failed");

        loan.approvedAt = block.timestamp;
        loan.status = LoanStatus.isApproved;

        if (block.timestamp >= loan.approvedAt + loanDurationInDays && loan.status == LoanStatus.isApproved) {
            // If the loan is not repaid within the loan duration,
            // transfer the collateral back to the lender
            uint256 _nftId = loan.nftId;
            loan.nft.safeTransferFrom(address(this), owner, _nftId);
            loan.status = LoanStatus.isOpen;
        }
    }

    function closeLoan(uint256 _loanId) public onlyOwner loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.isPaid, "Not Paid");
        

        // Transfer the loan amount to the contract owner
        (bool success, ) = payable(owner).call{value: loan.loanAmount}("");
        require(success, "Transfer failed");
        loan.status = LoanStatus.isClosed;
    }

    function repayLoan(uint256 _loanId) public payable loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.isApproved, "Not Approved");
        require(block.timestamp <= loan.approvedAt + loan.loanDuration, "Loan duration exceeded");
        require(msg.sender == loan.borrower, "Not Borrower");
        uint256 timeElapsed = block.timestamp - loan.approvedAt;
        uint256 interest_ = (loan.interestRate * timeElapsed) / (loanDurationInDays); // 5% monthly
        uint256 InterestAmount = interest_ * 1 ether;
        uint256 amount = loan.loanAmount + InterestAmount;
        uint256 _nftId = loan.nftId;
        require(msg.value >= amount, "Incorrect loan amount");
        loan.nft.safeTransferFrom(address(this), loan.borrower, _nftId);
 
        loan.loanAmount = amount;
        loan.borrower = owner;
        loan.nftId = 0;
        loan.status = LoanStatus.isPaid;
    }

    function getLoanIdsOfOngoingLoans() public view returns (uint256[] memory) {
        uint256 countOngoingLoans = 0;
        for (uint256 i = 0; i < loanCounter; i++) {
            if (loans[i].status == LoanStatus.isOpen || loans[i].status == LoanStatus.inReview) {
                countOngoingLoans++;
            }
        }

        uint256[] memory ongoingLoanIds = new uint256[](countOngoingLoans);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < loanCounter; i++) {
            if (loans[i].status == LoanStatus.isOpen || loans[i].status == LoanStatus.inReview) {
                ongoingLoanIds[currentIndex] = i; 
                currentIndex++;
            }
        }
        return ongoingLoanIds;
    }

    function getLoanIdsOfApprovedLoans() public view returns (uint256[] memory) {
        uint256 countApprovedLoans = 0;
        for (uint256 i = 0; i < loanCounter; i++) {
            if (loans[i].status == LoanStatus.isApproved) {
                countApprovedLoans++;
            }
        }

        uint256[] memory approvedLoanIds = new uint256[](countApprovedLoans);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < loanCounter; i++) {
            if (loans[i].status == LoanStatus.isApproved) {
                approvedLoanIds[currentIndex] = i; 
                currentIndex++;
            }
        }
        return approvedLoanIds;
    }

    function getInterest(uint256 _loanId) public view returns(uint256) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.isApproved, "Not Approved");
        require(block.timestamp <= loan.approvedAt + (loan.loanDuration * 1 days), "Loan duration exceeded");
        require(msg.sender == loan.borrower, "Not Borrower");
        uint256 timeElapsed = block.timestamp - loan.approvedAt;
        uint256 interest_ = (loan.interestRate * timeElapsed) / (loanDurationInDays); // 5% monthly
        return interest_ * 1 ether;
    }
}
